-- lua/utils/claude/slash.lua
--
-- The chat bar's "/" slash-command menu (OpenCode-style): a picker float that
-- pops ABOVE the "Reply to Claude" bar when the input line starts with "/", lists
-- the CLI's advertised slash commands (system/init.slash_commands[]), filters them
-- by prefix as the user types, and lets ↑/↓ cycle + <CR> insert the highlighted
-- command.
--
-- Two halves:
--   1. Description resolver — the stream-json only gives command NAMES (~200
--      plain strings, no descriptions), so we source `description:` frontmatter
--      from the on-disk skill/command files (~/.claude/skills, plugin caches,
--      project .claude) plus a small hardcoded map for the CLI's built-in and
--      bundled commands that have no file. Resolved once, cached module-side.
--   2. Menu float — a non-prompt scratch float the chat bar drives. It owns the
--      <CR> keymap on the chat buffer only while the menu is open (added on open,
--      removed on close), so the prompt buffer's normal submit is untouched when
--      no menu is showing. ↑/↓ and the typed-span coloring are driven by the chat
--      bar itself (init.lua open_chat_float), which queries Slash.active().
--
-- Dependencies: core.state, widgets.float_bottom_row (bar anchor row), and two
-- init-owned float helpers injected via Slash.wire{} (panel_float_geom +
-- harden_float_scroll), same pattern as widgets/gate/question.

local Slash = {}

local require_prefix = "utils.claude."
local core    = require(require_prefix .. "core")
local widgets = require(require_prefix .. "widgets")
local state   = core.state

-- Init-owned float helpers, injected by Slash.wire{} at load time.
local panel_float_geom
local harden_float_scroll

--- Inject init's float helpers. Called once from init after they are defined.
function Slash.wire(hooks)
  panel_float_geom    = hooks.panel_float_geom
  harden_float_scroll = hooks.harden_float_scroll
end

-- ─── Command-list disk cache (works before the first message) ─────────────────
-- The CLI only advertises slash_commands in system/init, which fires AFTER the
-- first user turn — so a fresh panel has no list until you send a message. To make
-- the "/" menu work immediately, we persist the authoritative names to disk the
-- first time any session emits them, and reload that cache on panel open. A later
-- init refreshes it. Only the very first run (empty cache) needs one message to seed.
-- Override via KODEX_CLAUDE_SLASH_CACHE so tests don't clobber the real cache.
local CACHE_PATH = vim.env.KODEX_CLAUDE_SLASH_CACHE
  or (vim.fn.stdpath("state") .. "/kodex_claude_slash_commands.json")

--- Persist the CLI's slash-command names for next session. Called from the init
--- capture (render.lua) with the freshly-advertised list.
function Slash.save_cache(names)
  if type(names) ~= "table" or #names == 0 then return end
  pcall(vim.fn.writefile, { vim.json.encode(names) }, CACHE_PATH)
end

--- Load the cached names into state.slash_commands when the live session hasn't
--- captured its own list yet (pre-first-message). The live init always overwrites
--- this, so a stale cache is only ever a brief head-start, never authoritative.
function Slash.ensure_commands()
  if state.slash_commands and #state.slash_commands > 0 then return end
  local ok, lines = pcall(vim.fn.readfile, CACHE_PATH)
  if not ok or not lines or not lines[1] then return end
  local ok2, names = pcall(vim.json.decode, lines[1])
  if ok2 and type(names) == "table" and #names > 0 then
    state.slash_commands = names
  end
end

-- ─── Description resolver ──────────────────────────────────────────────────────

-- Commands the PANEL implements locally (not advertised by the CLI's system/init
-- slash_commands, so they'd never appear otherwise). Merged into the menu list +
-- prefix/exact checks so they filter and highlight like any other command; their
-- descriptions live in BUILTIN_DESC. `/effort` opens the reasoning-effort slider;
-- `/advisor` opens the advisor-model picker. The CLI does NOT advertise /advisor
-- in slash_commands[] (it's a client-side modal, like /effort), so listing it here
-- is the only way it appears in the menu.
local LOCAL_COMMANDS = { "effort", "advisor" }

-- Built-in + CLI-bundled commands have NO on-disk frontmatter file (they ship
-- inside the claude binary), so their descriptions are hardcoded here. Anything
-- not covered by a file OR this map renders name-only (graceful degradation).
local BUILTIN_DESC = {
  agents          = "Manage agent configurations",
  clear           = "Clear conversation history",
  compact         = "Compact the conversation to save context",
  config          = "Open the config panel",
  context         = "Show context-window usage",
  init            = "Initialize a CLAUDE.md for this repo",
  help            = "Show help",
  ["release-notes"] = "Show release notes",
  review          = "Review a pull request",
  usage           = "Show usage limits",
  ["security-review"] = "Security-audit the current diff",
  ["code-review"] = "Review the current diff for bugs and cleanups",
  simplify        = "Simplify the changed code",
  verify          = "Verify a change works end-to-end",
  run             = "Launch and drive this project's app",
  debug           = "Debug a failing test or error",
  loop            = "Run a prompt or command on a recurring interval",
  schedule        = "Manage scheduled cloud agents",
  design          = "Design guidance for the current work",
  ["claude-api"]  = "Reference for the Claude API / Anthropic SDK",
  dataviz         = "Guidance for building charts and data visualizations",
  ["update-config"] = "Configure the Claude Code harness",
  recap           = "Recap recent work",
  insights        = "Show session insights",
  effort          = "Set the reasoning-effort level (opens a slider)",
  advisor         = "Choose the advisor model (opens a picker)",
}

-- name → resolved first-sentence description, or false when we looked and found
-- nothing (so we don't re-scan). nil = not yet resolved. Built lazily on first
-- menu open by ensure_descriptions().
local desc_cache = nil

-- Skill/command NAMES discovered by scanning the on-disk dirs (the same files the
-- description index reads). Sourced INTO the menu so a skill appears the moment its
-- file exists, WITHOUT waiting for the CLI to re-advertise slash_commands[] — that
-- list is a point-in-time snapshot captured at session init and disk-cached, so a
-- skill created after it never showed (the reported "new skills don't populate" bug).
-- nil until the first scan; refreshed on menu OPEN (Slash.open), not per keystroke.
-- disk_names_key is a signature of the last scan so we only rebuild the (heavier)
-- description cache when the set actually changed.
local disk_names     = nil
local disk_names_key = nil

-- Trim a raw description to a single leading sentence. Not length-capped — the
-- menu word-wraps it across indented rows (see render_menu), so the whole sentence
-- stays readable rather than being cut with an ellipsis.
local function first_sentence(d)
  if not d or d == "" then return nil end
  d = vim.trim(d)
  -- First sentence = up to the first ./!/? followed by space or end.
  local s = d:match("^(.-[%.%!%?])%s") or d:match("^(.-[%.%!%?])$") or d
  return vim.trim(s)
end

-- Parse a SKILL.md / command .md YAML frontmatter for its `name:` and
-- `description:` (supporting folded/literal block scalars: `description: >` then
-- indented lines). Returns name, desc (either may be nil). Reads only the head of
-- the file — frontmatter is always at the very top.
local function parse_frontmatter(path)
  local ok, lines = pcall(vim.fn.readfile, path, "", 60)
  if not ok or type(lines) ~= "table" or lines[1] ~= "---" then
    return nil, nil
  end
  local name, desc
  local i = 2
  while i <= #lines do
    local ln = lines[i]
    if ln == "---" then break end
    local nm = ln:match("^name:%s*(.+)$")
    if nm then name = vim.trim(nm):gsub('^["\']', ""):gsub('["\']$', "") end
    local dv = ln:match("^description:%s*(.*)$")
    if dv then
      dv = vim.trim(dv)
      if dv == ">" or dv == "|" or dv == ">-" or dv == "|-" or dv == "" then
        -- Block scalar: collect following indented (or blank) lines.
        local body = {}
        local j = i + 1
        while j <= #lines do
          local bl = lines[j]
          if bl:match("^%s") or bl == "" then
            local t = vim.trim(bl)
            if t ~= "" then body[#body + 1] = t end
            j = j + 1
          else
            break
          end
        end
        dv = table.concat(body, " ")
        i = j - 1
      end
      desc = vim.trim(dv):gsub('^["\']', ""):gsub('["\']$', "")
    end
    i = i + 1
  end
  return name, desc
end

-- Glob patterns for every place a skill/command frontmatter file can live. First
-- write wins (see index build below), so user skills take priority over plugin
-- copies, and marketplaces over cache mirrors.
local function candidate_files()
  local home = vim.fn.expand("~")
  local pats = {
    home .. "/.claude/skills/*/SKILL.md",
    home .. "/.claude/commands/*.md",
    home .. "/.claude/plugins/marketplaces/*/*/SKILL.md",
    home .. "/.claude/plugins/marketplaces/*/skills/*/SKILL.md",
    home .. "/.claude/plugins/marketplaces/*/commands/*.md",
    home .. "/.claude/plugins/cache/*/*/*/*/SKILL.md",
    home .. "/.claude/plugins/cache/*/*/*/skills/*/SKILL.md",
    home .. "/.claude/plugins/cache/*/*/*/commands/*.md",
    ".claude/skills/*/SKILL.md",
    ".claude/commands/*.md",
  }
  local out = {}
  for _, p in ipairs(pats) do
    for _, f in ipairs(vim.fn.glob(p, false, true)) do
      out[#out + 1] = f
    end
  end
  return out
end

-- Build the name→description index once. Indexes each file under BOTH its
-- frontmatter `name:` and its directory/file basename, so a namespaced slash
-- command ("plugin:skill") can resolve via the "skill" suffix (see resolve()).
local function build_index()
  local index = {}
  local function add(key, desc)
    if key and key ~= "" and desc and not index[key] then
      index[key] = first_sentence(desc)
    end
  end
  for _, path in ipairs(candidate_files()) do
    local nm, desc = parse_frontmatter(path)
    if desc then
      local base = vim.fn.fnamemodify(path, ":t:r")
      if base == "SKILL" then base = vim.fn.fnamemodify(path, ":h:t") end
      add(nm, desc)
      add(base, desc)
    end
  end
  for k, v in pairs(BUILTIN_DESC) do
    if not index[k] then index[k] = v end
  end
  return index
end

-- Resolve a slash-command name to a description string, or nil. Tries the exact
-- name, then (for "plugin:skill" names) the part after the colon.
local function resolve(name)
  if not desc_cache then return nil end
  local d = desc_cache[name]
  if d then return d end
  local suffix = name:match(":(.+)$")
  if suffix then return desc_cache[suffix] end
  return nil
end

-- Populate desc_cache on first use (one filesystem scan, then cached for the
-- session). Cheap enough to run inline on the first menu open (~200 small reads).
local function ensure_descriptions()
  if desc_cache then return end
  desc_cache = build_index()
end

-- Exposed for tests / manual refresh.
function Slash._resolve_desc(name)
  ensure_descriptions()
  return resolve(name)
end

-- The slash NAME each on-disk candidate file is invoked as: a skill's directory
-- basename (~/.claude/skills/<name>/SKILL.md → "<name>"), a command file's basename
-- (commands/<name>.md → "<name>"). These are the un-namespaced tokens typed after
-- "/"; plugin skills the CLI advertises namespaced ("plugin:skill") de-dupe against
-- these by suffix in all_commands(). Reuses candidate_files() (the description scan's
-- own glob set), so names and descriptions always come from the same files.
local function disk_command_names()
  local names, seen = {}, {}
  for _, path in ipairs(candidate_files()) do
    local base = vim.fn.fnamemodify(path, ":t:r")           -- file stem
    if base == "SKILL" then base = vim.fn.fnamemodify(path, ":h:t") end  -- dir name
    if base ~= "" and not seen[base] then
      seen[base] = true
      names[#names + 1] = base
    end
  end
  return names
end
Slash._disk_command_names = disk_command_names   -- test hook

-- Rescan disk for skill/command names (called on menu open). When the set changed
-- since the last scan (a skill was created/removed), drop the description cache so
-- the next resolve rebuilds it — otherwise a freshly-created skill would list its
-- name with no description until the session restarts.
local function refresh_disk_names()
  -- Slash._test_disk_names lets specs pin the disk-discovered set to a known list
  -- (or {} to neutralise it) so menu-lifecycle assertions don't depend on whatever
  -- skills happen to exist on the test machine. nil in normal use → real scan.
  local fresh = Slash._test_disk_names or disk_command_names()
  local sorted = vim.deepcopy(fresh)
  table.sort(sorted)
  local key = table.concat(sorted, "\n")
  if key ~= disk_names_key then
    disk_names_key = key
    desc_cache = nil   -- force a rebuild so new skills also get their descriptions
  end
  disk_names = fresh
end
Slash._refresh_disk_names = refresh_disk_names   -- test hook

-- ─── Menu float ────────────────────────────────────────────────────────────────

local MAX_ROWS  = 12          -- screen-row budget for the visible menu. Items are
                             -- variable height (a name row + wrapped description
                             -- rows + a separator), so the viewport is sized by
                             -- total rows, not a fixed item count. See render_menu.

-- Strip a namespaced command ("plugin:skill") down to its display label — the
-- run after the last ":". The panel is narrow, so the "plugin:" half is pure
-- noise in the menu; we still filter/insert/resolve on the FULL name (see
-- render_menu + accept_selected), only the shown label is shortened.
local function display_name(name)
  return name:match("([^:]+)$") or name
end

-- Hard-cap a string to `width` display cells with an ellipsis, so a description
-- can't spill past the (nowrap) float's right edge.
local function fit_width(s, width)
  if width < 2 then return "" end
  if vim.fn.strdisplaywidth(s) > width then
    s = vim.fn.strcharpart(s, 0, width - 1) .. "…"
  end
  return s
end

-- Greedy word-wrap `s` into a list of lines each <= `width` display cells. We wrap
-- in Lua (rather than letting the window soft-wrap) so the float's height can stay
-- equal to its buffer line count — the invariant the nowrap arrow fix depends on.
-- A single word longer than `width` is clamped with an ellipsis (rare in a
-- first-sentence description).
local function wrap_text(s, width)
  local out, cur = {}, ""
  for word in s:gmatch("%S+") do
    local cand = cur == "" and word or (cur .. " " .. word)
    if vim.fn.strdisplaywidth(cand) <= width then
      cur = cand
    else
      if cur ~= "" then out[#out + 1] = cur end
      cur = word
    end
  end
  if cur ~= "" then out[#out + 1] = cur end
  for i, l in ipairs(out) do out[i] = fit_width(l, width) end
  return out
end

-- Live menu state (module-local; only ever one menu at a time, tied to the one
-- chat bar). items = filtered command names, sel = 1-based highlighted index,
-- top = first visible row (scroll offset).
local menu = {
  win = nil, buf = nil, ns = nil,
  ibuf = nil,           -- the chat prompt buffer the menu is attached to
  items = {},
  sel = 1,
  top = 1,
  on_accept = nil,      -- called with the chosen command name
}

--- True while the slash menu is open. The chat bar queries this to route ↑/↓/<Esc>.
function Slash.active()
  return menu.win ~= nil and vim.api.nvim_win_is_valid(menu.win)
end

-- The full command universe: the CLI-advertised names plus the panel's own
-- LOCAL_COMMANDS (deduped — a local name already advertised isn't added twice).
-- Every menu/prefix/exact check goes through this so local commands behave like
-- advertised ones.
local function all_commands()
  local out, seen, suffix_seen = {}, {}, {}
  local function push(name)
    if name and name ~= "" and not seen[name] then
      seen[name] = true; out[#out + 1] = name
    end
  end
  for _, name in ipairs(state.slash_commands or {}) do
    push(name)
    suffix_seen[name:match("([^:]+)$") or name] = true   -- "plugin:skill" ⇒ "skill"
  end
  for _, name in ipairs(LOCAL_COMMANDS) do push(name) end
  -- Disk-discovered skills/commands (see disk_command_names): the source that makes
  -- newly-created skills appear without a CLI re-advertise. Skip any name already
  -- advertised exactly OR present as the suffix of a namespaced advertised name
  -- ("caveman:caveman" already covers a disk "caveman"), so nothing shows twice.
  for _, name in ipairs(disk_names or {}) do
    if not suffix_seen[name] then push(name) end
  end
  return out
end
Slash._all_commands = all_commands   -- test hook (dedup / merge assertions)

-- Prefix-filter the full command list by `query` (the text after "/"), sorted.
local function filter_commands(query)
  local q = (query or ""):lower()
  local out = {}
  for _, name in ipairs(all_commands()) do
    if q == "" or name:lower():sub(1, #q) == q then
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

--- True when `name` is an EXACT known command — matched against the full
--- advertised name OR its post-":" suffix (so the shortened label the menu shows,
--- e.g. "ce-code-review" for "compound-engineering:ce-code-review", also counts).
--- Drives the "highlight a valid /command anywhere in the line" colouring.
function Slash.is_command(name)
  if not name or name == "" then return false end
  for _, n in ipairs(all_commands()) do
    if n == name or n:match("([^:]+)$") == name then return true end
  end
  return false
end

--- True when `query` is a prefix of at least one command (drives the input-span
--- "valid vs no-match" coloring in the chat bar). An empty query is always valid.
function Slash.has_prefix(query)
  if not query or query == "" then return true end
  local q = query:lower()
  for _, name in ipairs(all_commands()) do
    if name:lower():sub(1, #q) == q then return true end
  end
  return false
end

-- Redraw the menu buffer from menu.items/sel/top.
--
-- Each item renders as a "/label" row plus its word-wrapped, indented description
-- rows (blank line between items). Items are therefore VARIABLE height, so the
-- visible window is chosen by a screen-row budget (MAX_ROWS) rather than a fixed
-- item count, and we scroll to keep the selected item inside it. We wrap the
-- description ourselves (wrap_text) and keep the float nowrap so its height always
-- equals its buffer line count — the invariant that keeps ↑/↓ and the highlight
-- in sync (the old soft-wrap bug pushed the selected row below the fold).
local function render_menu()
  if not (menu.buf and vim.api.nvim_buf_is_valid(menu.buf)) then return end
  local n = #menu.items

  local width = 40
  if menu.win and vim.api.nvim_win_is_valid(menu.win) then
    width = vim.api.nvim_win_get_config(menu.win).width
  end
  local indent = "    "
  local dwidth = math.max(width - #indent - 1, 8)   -- desc wrap width (leave a margin)

  -- Empty state: one diagnostic line, no items.
  if n == 0 then
    -- Distinguish "the CLI never advertised any commands" (list not captured yet —
    -- send a message so system/init fires, or restart) from "your query matched
    -- none of the loaded commands". Makes an empty live session self-diagnosing.
    local loaded = state.slash_commands and #state.slash_commands > 0
    local msg = loaded and " no matching commands"
                        or " commands not loaded yet — send a message first"
    vim.bo[menu.buf].modifiable = true
    vim.api.nvim_buf_set_lines(menu.buf, 0, -1, false, { msg })
    vim.bo[menu.buf].modifiable = false
    if menu.win and vim.api.nvim_win_is_valid(menu.win) then
      local c = vim.api.nvim_win_get_config(menu.win)
      if c.height ~= 1 then c.height = 1; vim.api.nvim_win_set_config(menu.win, c) end
    end
    vim.api.nvim_buf_clear_namespace(menu.buf, menu.ns, 0, -1)
    return
  end

  -- Build one item's render block: the "/label" line + its wrapped desc lines.
  local function build(i)
    local name  = menu.items[i]
    local label = "/" .. display_name(name)
    local desc  = resolve(name) or ""
    local blk = { name_line = " " .. label, name_end = 1 + #label, desc_lines = {} }
    for _, l in ipairs(desc ~= "" and wrap_text(desc, dwidth) or {}) do
      blk.desc_lines[#blk.desc_lines + 1] = indent .. l
    end
    blk.height = 1 + #blk.desc_lines
    return blk
  end

  -- Row-budget viewport: accumulate item heights from menu.top (a blank separator
  -- line between items) until the budget is spent, then scroll down until the
  -- selected item fits. The first item is always kept even if taller than the
  -- budget, so this always terminates.
  if menu.sel < menu.top then menu.top = menu.sel end
  if menu.top < 1 then menu.top = 1 end
  local function window()
    local blks, last, used = {}, menu.top - 1, 0
    for i = menu.top, n do
      local b = build(i)
      local h = b.height + (i > menu.top and 1 or 0)   -- +1 for the separator line
      if used + h > MAX_ROWS and i > menu.top then break end
      used, last, blks[i] = used + h, i, b
    end
    return blks, last
  end
  local blocks, last = window()
  while menu.sel > last do
    menu.top = menu.top + 1
    blocks, last = window()
  end

  -- Flatten the visible blocks into buffer lines, recording each item's absolute
  -- line span for the highlight pass.
  local lines, rows = {}, {}
  for i = menu.top, last do
    local b = blocks[i]
    if i > menu.top then lines[#lines + 1] = "" end   -- blank separator between items
    local name_lnum = #lines
    lines[#lines + 1] = b.name_line
    local desc_lnums = {}
    for _, dl in ipairs(b.desc_lines) do
      desc_lnums[#desc_lnums + 1] = #lines
      lines[#lines + 1] = dl
    end
    rows[#rows + 1] = {
      name_lnum = name_lnum, name_end = b.name_end,
      desc_lnums = desc_lnums, sel = (i == menu.sel),
    }
  end

  vim.bo[menu.buf].modifiable = true
  vim.api.nvim_buf_set_lines(menu.buf, 0, -1, false, lines)
  vim.bo[menu.buf].modifiable = false

  -- Resize the float to the line count. Nowrap ⇒ line count == screen rows, so
  -- every visible item stays on-screen and the highlight can't scroll off.
  if menu.win and vim.api.nvim_win_is_valid(menu.win) then
    local c = vim.api.nvim_win_get_config(menu.win)
    if c.height ~= #lines then
      c.height = math.max(#lines, 1)
      vim.api.nvim_win_set_config(menu.win, c)
    end
  end

  -- Highlights: the selected item bands its name + every desc row; unselected
  -- items colour the name span and dim their desc rows.
  vim.api.nvim_buf_clear_namespace(menu.buf, menu.ns, 0, -1)
  local function band(lnum)
    vim.api.nvim_buf_set_extmark(menu.buf, menu.ns, lnum, 0, {
      end_row = lnum + 1, hl_group = "ClaudeSlashSel", hl_eol = true,
    })
  end
  for _, meta in ipairs(rows) do
    if meta.sel then
      -- Selected: a full-width band with dark text. Don't layer name/desc fg
      -- colours on top — they'd render clay-on-clay (invisible).
      band(meta.name_lnum)
      for _, dl in ipairs(meta.desc_lnums) do band(dl) end
    else
      -- Command name (cols 1..name_end, after the 1-space left gutter).
      vim.api.nvim_buf_set_extmark(menu.buf, menu.ns, meta.name_lnum, 1, {
        end_col = meta.name_end, hl_group = "ClaudeSlashName",
      })
      for _, dl in ipairs(meta.desc_lnums) do
        vim.api.nvim_buf_set_extmark(menu.buf, menu.ns, dl, 0, {
          end_row = dl + 1, hl_group = "ClaudeSlashDesc",
        })
      end
    end
  end
end

--- Close the menu float + remove the <CR> keymap it owns on the chat buffer.
function Slash.close()
  if menu.ibuf and vim.api.nvim_buf_is_valid(menu.ibuf) then
    pcall(vim.keymap.del, "i", "<CR>", { buffer = menu.ibuf })
  end
  if menu.win and vim.api.nvim_win_is_valid(menu.win) then
    vim.api.nvim_win_close(menu.win, true)
  end
  menu.win, menu.buf, menu.ns, menu.ibuf = nil, nil, nil, nil
  menu.items, menu.sel, menu.top, menu.on_accept = {}, 1, 1, nil
end

--- Move the highlighted row by delta (±1), clamped. No-op if the menu is closed.
function Slash.move(delta)
  if not Slash.active() or #menu.items == 0 then return end
  menu.sel = menu.sel + delta
  if menu.sel < 1 then menu.sel = 1 end
  if menu.sel > #menu.items then menu.sel = #menu.items end
  render_menu()
end

--- The currently highlighted command name, or nil.
function Slash.selected()
  return menu.items[menu.sel]
end

-- Insert the highlighted command into the chat buffer ("/name ") and close the
-- menu. Wired as the menu's <CR> handler.
local function accept_selected()
  local name = Slash.selected()
  local ibuf, cb = menu.ibuf, menu.on_accept
  Slash.close()
  if name and ibuf and vim.api.nvim_buf_is_valid(ibuf) then
    -- Prompt buffers keep the "❯ " prompt AS part of the last line, so re-prepend
    -- it or the arrow vanishes. The trailing space lets the user type args and
    -- closes the menu (a space after the command means "command chosen").
    local prompt = vim.fn.prompt_getprompt(ibuf) or ""
    local text = "/" .. name .. " "
    local lnum = vim.api.nvim_buf_line_count(ibuf) - 1
    vim.api.nvim_buf_set_lines(ibuf, lnum, lnum + 1, false, { prompt .. text })
    -- Park the cursor at end of the inserted text (stay in insert mode).
    if vim.api.nvim_get_current_buf() == ibuf then
      vim.api.nvim_win_set_cursor(0, { lnum + 1, #(prompt .. text) })
    end
  end
  if cb then cb(name) end
end

-- Compute the menu's SW anchor. `bar_rows` is the chat bar's full occupied height
-- (interior + 2 border), so the menu sits directly above it.
local function menu_anchor(bar_rows)
  local col, width = panel_float_geom()
  local bottom = widgets.float_bottom_row() - (bar_rows or 3) - 1
  return col, width, bottom
end

--- Open (or re-filter, if already open) the slash menu for `query` (text after
--- "/"). `bar_rows` is the chat bar's occupied height so the menu floats above it.
--- `ibuf` is the chat prompt buffer; `on_accept(name)` fires when a command is
--- picked (chat bar uses it to re-fit + refocus). Idempotent: safe to call on
--- every keystroke.
function Slash.open(ibuf, query, bar_rows, on_accept)
  -- Rescan disk for skill/command names once per menu OPEN (this fn runs on every
  -- keystroke while the menu is live, so gate on the not-yet-open state). Reopening
  -- the menu after creating a skill re-globs and surfaces it — no restart needed.
  if not Slash.active() then refresh_disk_names() end
  ensure_descriptions()
  Slash.ensure_commands()   -- seed from the disk cache if this session hasn't captured a list yet
  menu.items = filter_commands(query)
  -- The query just changed (this is only called on a text change), so the filter
  -- is new — reset the highlight to the top row. ↑/↓ navigation goes through
  -- Slash.move, not here, so it isn't clobbered while cycling.
  menu.sel = 1
  menu.top = 1

  local col, width, row = menu_anchor(bar_rows)

  if not Slash.active() then
    menu.ibuf = ibuf
    menu.on_accept = on_accept
    menu.ns = vim.api.nvim_create_namespace("claude_slash_menu")
    menu.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[menu.buf].bufhidden = "wipe"
    vim.bo[menu.buf].modifiable = false
    menu.win = vim.api.nvim_open_win(menu.buf, false, {
      relative = "editor", anchor = "SW",
      row = row, col = col, width = width, height = 1,
      border = "rounded", style = "minimal", focusable = false,
      -- ABOVE the Clawd pet carrier (250) + its border patch (251): a winblend
      -- float ERASES the glyphs of any float below it in the nvim compositor, so
      -- with the menu underneath, the pet carrier bit a rectangle out of the menu
      -- border/text (live 2026-07-11). With the menu on top its cells win the
      -- grid; the kitty SPRITE still composites above all text (terminal layer),
      -- so Clawd stands on the chat bar in front of the menu — the wanted look.
      -- image.nvim window_overlap_clear is default-off, so the higher menu float
      -- does not make it hide the sprite. Cards stay at 60/70: Clawd sits on them.
      zindex = 300,
    })
    vim.wo[menu.win].winhighlight =
      "NormalFloat:ClaudeSlashBg,FloatBorder:ClaudeSlashBorder"
    -- Nowrap is load-bearing, not cosmetic: render_menu sets the float height to
    -- the buffer's LINE count, which only equals the on-screen row count when no
    -- line wraps. With wrap on, long descriptions spilled onto extra screen rows,
    -- shoved the selected row below the visible fold, and made ↑/↓ look dead.
    vim.wo[menu.win].wrap = false
    harden_float_scroll(menu.win)
    -- The menu owns <CR> on the chat buffer only while open: pick the highlighted
    -- command instead of submitting. Removed in Slash.close() so the prompt
    -- buffer's normal submit returns.
    vim.keymap.set("i", "<CR>", accept_selected,
      { buffer = ibuf, nowait = true, silent = true })
  else
    -- Already open: just re-place (bar height may have changed) + redraw.
    local c = vim.api.nvim_win_get_config(menu.win)
    c.row, c.col, c.width = row, col, width
    vim.api.nvim_win_set_config(menu.win, c)
  end
  render_menu()
end

return Slash
