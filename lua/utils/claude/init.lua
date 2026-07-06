-- lua/utils/claude.lua
--
-- Claude Code panel — bidirectional stream-json subprocess + custom renderer.
--
-- Architecture: NOT a toggleterm TUI panel (unlike opencode.lua). Instead,
-- `claude` is spawned as a long-lived subprocess via vim.fn.jobstart() with
-- stdin="pipe", and its stdout is parsed as newline-delimited JSON events that
-- are rendered into a custom nomodifiable scratch buffer ("claude"). This is a
-- direct port of kos-capture/screens/ingest.py into Lua.
--
-- Why jobstart, not vim.system?
--   vim.system is fire-and-forget (one-shot async). jobstart keeps the channel
--   open so we can write JSON user messages to stdin at any time — the only API
--   that works for an interactive bidirectional subprocess.
--
-- Why a custom render buffer, not :terminal?
--   :terminal would show Claude Code's raw TUI (ANSI escape sequences, blinking
--   cursors, status bars). We want IDE-native rendering: Neovim highlight groups,
--   manual folds for thinking blocks, and a virtual-text input hint. The custom
--   buffer gives us full control over what the panel looks like.
--
-- Design references:
--   FINDINGS.md § Claude Code Panel  — all architectural decisions
--   neo-claude.md §6                 — implementation outline
--   kos-capture/screens/ingest.py   — Python reference implementation (port source)

local mod = {}

-- Single require-prefix constant for intra-package modules. When the panel is
-- extracted as a standalone plugin (planned), the move to lua/kodex-claude/ is a
-- one-line change here per module (Goal 15 packaging rule).
local require_prefix = "utils.claude."
local core = require(require_prefix .. "core")
local markdown = require(require_prefix .. "markdown")
local widgets = require(require_prefix .. "widgets")
local question = require(require_prefix .. "question")
local gate = require(require_prefix .. "gate")
local process = require(require_prefix .. "process")
local render = require(require_prefix .. "render")
local slash = require(require_prefix .. "slash")
local effort = require(require_prefix .. "effort")
local advisor = require(require_prefix .. "advisor")

-- Full path required — ~/.local/bin is only on PATH in interactive bash, never
-- in Neovim's environment. Matches the OPENCODE_BIN pattern in opencode.lua
-- (findings Q12). vim.fn.expand resolves "~" at call time.
mod.CLAUDE_BIN = vim.fn.expand("~/.local/bin/claude")

--- Guard: returns true iff the claude binary exists and is executable.
-- Does NOT attempt /login or any auth check — /login is interactive inside
-- the agent and cannot be tested programmatically at launch.
---@return boolean
function mod.is_available()
  return vim.fn.executable(mod.CLAUDE_BIN) == 1
end

-- Centralised guard called before toggle / ask_selection. Shows an error notify
-- once and returns false, so callers can exit early with a single line.
local function ensure_available()
  if mod.is_available() then return true end
  vim.notify(
    "claude not found at ~/.local/bin/claude — install Claude Code",
    vim.log.levels.ERROR
  )
  return false
end

-- Panel winhighlight: background + end-of-buffer highlight, scoped to this window.
-- NOTE: winhighlight cannot override Cursor/CursorNC (see :h winhighlight — those
-- groups are explicitly excluded). Cursor hiding is done via guicursor WinEnter/WinLeave.
-- Folded:ClaudeLabel paints the collapsed "▶ Thought" foldtext row in the same
-- bold purple as the expanded header, so the block reads consistently in either state.
local PANEL_HL_BASE = "Normal:ClaudeNormal,NormalNC:ClaudeNormal,EndOfBuffer:ClaudeNormal,Folded:ClaudeLabel"

-- ─── Shared state + core primitives ───────────────────────────────────────────
--
-- state / opts / the buffer+highlight primitives live in claude/core.lua so the
-- render sub-modules can share them. Re-export state as mod.state (SAME table
-- identity — claude_diff.lua and other consumers mutate it) and bind the core
-- primitives as file-local names so every existing call site below is unchanged.

mod.state = core.state
local state = mod.state
local opts  = core.opts

local panel_width = core.panel_width
local sep_line    = core.sep_line
local buf_append  = core.buf_append
local hl_lines    = core.hl_lines
local hl_range    = core.hl_range
local free_below  = core.free_below

-- Markdown render engine (claude/markdown.lua). Only the entry points that init's
-- dispatch/render paths call directly are bound here; the rest stay private to the
-- module. build_md_lines/render_table also back the mod._* test hooks below.
local build_md_lines    = markdown.build_md_lines
local render_table      = markdown.render_table
local render_code_block = markdown.render_code_block
local is_fence          = markdown.is_fence
local wrap_text         = markdown.wrap_text
local disp_take         = markdown.disp_take

--- Merge user-provided options from the lazy plugin spec (FINDINGS.md Q9).
-- Idempotent — safe to call multiple times (last call wins for each key). Merges
-- IN PLACE so core.opts keeps its table identity (panel_width reads it there).
function mod.setup(user_opts)
  local merged = vim.tbl_deep_extend("force", opts, user_opts or {})
  for k in pairs(opts) do opts[k] = nil end
  for k, v in pairs(merged) do opts[k] = v end
end


-- ─── Model display names + session id (port of ingest.py _MODEL_NAMES) ───────

-- Model-id → friendly display name. Substring match (model ids carry date
-- suffixes), so "claude-opus-4-8" → "Opus 4.8". Mirrors ingest.py _MODEL_NAMES;
-- the most recent ids come first so a longer id never shadows a shorter prefix.
local MODEL_NAMES = {
  { "claude-fable-5",             "Fable 5" },
  { "claude-opus-4-8",            "Opus 4.8" },
  { "claude-opus-4-7",           "Opus 4.7" },
  { "claude-opus-4-6",           "Opus 4.6" },
  { "claude-sonnet-5",           "Sonnet 5" },
  { "claude-sonnet-4-6",         "Sonnet 4.6" },
  { "claude-haiku-4-5",          "Haiku 4.5" },
  { "claude-opus-4-5",           "Opus 4.5" },
  { "claude-sonnet-4-5",         "Sonnet 4.5" },
  { "claude-3-5-sonnet",         "Sonnet 3.5" },
  { "claude-3-opus",             "Opus 3" },
  { "claude-3-haiku",            "Haiku 3" },
  -- Bare aliases (from the <leader>cm picker, before system/init confirms the
  -- exact id) → the friendly name of the latest model in each family. Listed
  -- LAST so a full date-suffixed id always matches its specific entry first.
  { "opus",                      "Opus 4.8" },
  { "sonnet",                    "Sonnet 5" },
  { "haiku",                     "Haiku 4.5" },
}

-- Map a raw model id to its friendly name, falling back to the id itself when
-- unknown (so a new model still shows something rather than a blank line).
local function friendly_model(model_id)
  if not model_id or model_id == "" then return "" end
  for _, pair in ipairs(MODEL_NAMES) do
    if model_id:find(pair[1], 1, true) then return pair[2] end
  end
  return model_id
end

-- Claude Code version derived from the binary's install path WITHOUT spawning a
-- session. The launcher (~/.local/bin/claude) symlinks into
-- ~/.local/share/claude/versions/<version>, so the realpath's basename is the
-- version string (e.g. "2.1.186"). Lets the banner show the version at panel
-- open, before system/init (which only arrives after the first message). Mirrors
-- KOS Capture's realpath fallback. Returns "" if the path can't be resolved.
local function binary_version()
  local rp = vim.loop.fs_realpath(mod.CLAUDE_BIN)
  if not rp then return "" end
  local base = vim.fn.fnamemodify(rp, ":t")
  -- Only accept a version-looking basename (digits + dots); otherwise blank.
  return base:match("^%d[%d%.]*$") and base or ""
end

-- Tool verb/HL tables + tool_target moved to claude/render.lua (Goal 15.7).

-- ─── Buffer append helper ─────────────────────────────────────────────────────


-- Forward-declared (defined below) so buf_append's auto-follow can, when the chat
-- bar is open, RE-PLACE the bottom pad at the new last line and lift it above the
-- bar — instead of scrolling it flush to the window bottom (under the float).
local anchor_last_line
local set_bottom_pad




-- ─── Virtual text hint (bottom of panel) ─────────────────────────────────────

-- Replace the hint at the end of the buffer with new text. The hint is a
-- virtual-text extmark — it appears after the last real line but is not buffer
-- content (cannot be yanked, deleted, or accidentally submitted as input).
--
-- Why extmark virtual text instead of a real line?
--   If we wrote "Reply to Claude…" as a real buffer line and the user pressed
--   <CR>, the input remaps (see set_panel_keymaps) would fire — but the text
--   would also be visible in :Telescope buffers, grep results, etc. Virtual text
--   is display-only.
local function set_hint(text, hl)
  local buf = state.panel_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  vim.api.nvim_buf_clear_namespace(buf, state.hint_ns, 0, -1)
  local last = vim.api.nvim_buf_line_count(buf) - 1
  if last < 0 then last = 0 end
  hl = hl or "ClaudeInput"
  -- eol virtual text does NOT soft-wrap — a long hint just runs off the right
  -- edge. So hard-wrap to the live panel width and spill the overflow into
  -- virt_lines stacked below. Explicit "\n" in `text` forces a break too (the
  -- spinner's "<Esc> to interrupt" footer rides on its own line). When the panel
  -- is the only window it's wide, so the hint stretches across that real estate.
  local w = math.max(panel_width() - 1, 20)
  local segments = {}
  for _, para in ipairs(vim.split(text, "\n", { plain = true })) do
    for _, wl in ipairs(wrap_text(para, w)) do
      segments[#segments + 1] = wl
    end
  end
  if #segments == 0 then return end
  -- First segment sits at the end of the last buffer line; the rest become
  -- virtual lines so the whole hint stacks vertically inside the window.
  local virt_lines
  if #segments > 1 then
    virt_lines = {}
    for i = 2, #segments do
      virt_lines[i - 1] = { { segments[i], hl } }
    end
  end
  vim.api.nvim_buf_set_extmark(buf, state.hint_ns, last, 0, {
    virt_text     = { { segments[1], hl } },
    virt_text_pos = "eol",
    virt_lines    = virt_lines,
  })
end

local function clear_hint()
  local buf = state.panel_buf
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, state.hint_ns, 0, -1)
  end
end

-- ─── Bottom pad (keep output above the chat float) ────────────────────────────
--
-- The reply float overlays the panel's bottom rows. We anchor `rows` blank virtual
-- lines to the buffer's last line; `normal! G` then scrolls them into view at the
-- very bottom (under the float, invisible), lifting the last REAL content line to
-- just above the bar. Re-applied as the float grows; cleared when the bar closes.
-- The over-scroll clamp only limits USER scroll, so this programmatic follow isn't
-- fought.

-- Pin the panel's view so the last REAL content line sits exactly `reserve` screen
-- rows above the window bottom — the space the chat bar's pad reserves. With no pad
-- (reserve 0, bar closed) the last line sits flush at the bottom (reflow).
--
-- Method: `G`+`zb` gets close, then a screen-row measurement (free_below) drives a
-- single `<C-e>` correction to hit `reserve` precisely. We do NOT compute a topline:
--   - The old topline walk summed nvim_win_text_height PER LINE, which returns 0 for
--     lines inside a CLOSED FOLD (a collapsed "thinking" dropdown) — so the walk ran
--     far past the intended top and the view jumped 10-20 lines.
--   - `zb` alone is wrap/fold-correct but does not reliably account for the trailing
--     virtual PAD lines (how many land on-screen depends on the last line's wrap
--     height), so it under-lifts by a row or two.
-- Measuring the real rendered gap and nudging with `<C-e>` sidesteps both. It needs
-- 'smoothscroll' (panel-window-local) so `<C-e>` moves ONE screen row, not a whole
-- (possibly multi-row) buffer line; scrolloff is forced to 0 so nothing holds the
-- last line off the bottom. Only ever scrolls UP toward the bar (never <C-y>): a
-- short conversation that can't fill the window just floats above the bar, which is
-- correct — forcing it down would hide the top of the chat.
function anchor_last_line(win, reserve)
  if not (win and vim.api.nvim_win_is_valid(win)) then return end
  local buf = vim.api.nvim_win_get_buf(win)
  pcall(vim.api.nvim_win_call, win, function()
    if vim.api.nvim_buf_line_count(buf) < 1 then return end
    local so = vim.wo[win].scrolloff
    vim.wo[win].scrolloff = 0
    vim.cmd("keepjumps normal! Gzb")
    local fb = free_below(win, buf)
    if fb and fb < reserve then
      vim.cmd("keepjumps normal! " .. (reserve - fb) .. "\005")  -- <C-e> ×(reserve-fb)
    end
    vim.wo[win].scrolloff = so
  end)
end

-- `rows` is the BASE reserve the caller (chat bar / question float) wants. The
-- ACTUAL pad also includes the bottom-pinned task widget's height so transcript
-- content clears BOTH. state.chat_pad = the base (re-fed on re-place/re-anchor to
-- avoid double-counting the widget); state.pad_rows = the effective total the
-- WinScrolled clamp reads.
function set_bottom_pad(rows)
  local buf = state.panel_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf) and state.pad_ns) then return end
  state.chat_pad = (rows and rows >= 1) and rows or 0
  local total = state.chat_pad + (widgets.todo_height and widgets.todo_height() or 0)
  vim.api.nvim_buf_clear_namespace(buf, state.pad_ns, 0, -1)
  state.pad_rows = total
  local is_panel = state.panel_win and vim.api.nvim_win_is_valid(state.panel_win)
    and vim.api.nvim_win_get_buf(state.panel_win) == buf
  if total < 1 then
    if is_panel then anchor_last_line(state.panel_win, 0) end
    return
  end
  local last = math.max(vim.api.nvim_buf_line_count(buf) - 1, 0)
  -- `total` blank pad lines below the last real line fill the area the floats cover
  -- (plus a visible separator row), giving topline real content to lift the last
  -- line clear of the bar + widget.
  local vlines = {}
  for _ = 1, total do vlines[#vlines + 1] = { { "", "ClaudeNormal" } } end
  vim.api.nvim_buf_set_extmark(buf, state.pad_ns, last, 0, { virt_lines = vlines })
  if is_panel then anchor_last_line(state.panel_win, total) end
end

-- Drop the chat/question float's base reserve. The task widget (if visible) keeps
-- its own reserve, so route through set_bottom_pad(0) rather than clearing raw.
local function clear_bottom_pad()
  set_bottom_pad(0)
end

-- Re-pin the last content line to its resting position when a pad is reserved.
-- Toggling a thinking fold inserts/removes display rows ABOVE the last line while
-- the topline holds, so the line slides relative to the window bottom — on EXPAND
-- it drops below its anchor and hides UNDER the question card / chat bar. Re-running
-- set_bottom_pad re-anchors it to `pad_rows` above the bottom. No-op with no pad.
local function reanchor_pad()
  if (state.chat_pad or 0) > 0 or (widgets.todo_height and widgets.todo_height() > 0) then
    set_bottom_pad(state.chat_pad or 0)
  end
end

-- Test seams: expose the pad/anchor internals so the headless spec can drive the
-- exact push-up math (winh/line-count/topline) without an interactive float.
mod._anchor_last_line = anchor_last_line
mod._set_bottom_pad   = set_bottom_pad
mod._clear_bottom_pad = clear_bottom_pad
mod._reanchor_pad     = reanchor_pad

-- Wire set_bottom_pad into core.buf_append's auto-follow pad path (buf_append lives
-- in core.lua now but must re-place the pad on streaming appends). Deferred to here
-- because set_bottom_pad couples to the chat-bar/widget logic that stays in init.
core.wire_set_bottom_pad(set_bottom_pad)

-- ─── Queued-message display (type-ahead while Claude works) ───────────────────

-- Render the pending message queue as shaded virtual lines anchored to the
-- buffer's current last line, so they sit at the very bottom under the spinner.
-- Re-anchored on each spinner tick (the last line moves as output streams) and
-- whenever the queue changes. Cleared when the queue empties.
local function render_queue()
  local buf = state.panel_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf) and state.queue_ns) then return end
  vim.api.nvim_buf_clear_namespace(buf, state.queue_ns, 0, -1)
  if #state.queue == 0 then return end
  local last = vim.api.nvim_buf_line_count(buf) - 1
  if last < 0 then last = 0 end
  local vlines = {}
  for _, t in ipairs(state.queue) do
    -- compact single-line preview (queued multi-line messages collapse to line 1)
    local preview = vim.split(t, "\n", { plain = true })[1]
    vlines[#vlines + 1] = { { "❯ " .. preview .. "   (queued)", "ClaudeQueued" } }
  end
  vim.api.nvim_buf_set_extmark(buf, state.queue_ns, last, 0, {
    virt_lines = vlines,
  })
end

-- ─── Working spinner ──────────────────────────────────────────────────────────

-- Braille frames cycled while a turn is in flight. The hint is anchored to the
-- buffer's last line; in send() we append a blank line after the user echo so
-- the spinner first appears on its OWN line beneath the entry, then trails the
-- streaming output as it arrives.
local SPINNER = { "⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷" }
local spin_i  = 1

-- Human-readable duration: sub-minute reads "3.2s", longer "1m 04s". Used by the
-- live spinner (turn elapsed), the thinking fold ("Thought · 3.2s"), and the
-- "✻ Churned for …" done line. Defined here (above spinner_label) so the spinner
-- timer can reach it — a later definition resolves to a nil global and errors.
local function fmt_think_dur(ms)
  local s = ms / 1000
  if s < 60 then return string.format("%.1fs", s) end
  return string.format("%dm %02ds", math.floor(s / 60), math.floor(s % 60))
end

-- Flavour words for the generic model-generation phase (the boring "Working…"),
-- mirroring the official TUI's rotating verb. Gerund form for the live spinner;
-- FLAVOR_DONE is the past-tense set for the "✻ Churned for 4m 31s" final line.
-- Index-aligned: the turn picks one index (state.flavor_idx); the live spinner
-- shows FLAVOR[idx] and the done line shows FLAVOR_DONE[idx], so the close is the
-- past tense of the open ("Proofing…" → "✻ Proofed for 4m"). Keep both in sync.
local FLAVOR = {
  "Accomplishing", "Actioning", "Actualizing", "Baking", "Befuddling", "Boggling",
  "Boondoggling", "Booping", "Brewing", "Calculating", "Cerebrating", "Channelling",
  "Churning", "Clauding", "Coalescing", "Cogitating", "Combobulating", "Computing",
  "Concocting", "Conjuring", "Considering", "Cooking", "Crafting", "Creating",
  "Crunching", "Deliberating", "Determining", "Discombobulating", "Doing", "Doodling",
  "Effecting", "Elucidating", "Enchanting", "Envisioning", "Finagling", "Forging",
  "Forming", "Frolicking", "Galloping", "Generating", "Germinating", "Hatching",
  "Herding", "Honking", "Hustling", "Hyperspacing", "Ideating", "Imagining",
  "Incubating", "Inferring", "Jazzing", "Jiving", "Levitating", "Manifesting",
  "Marinating", "Meandering", "Moseying", "Mulling", "Musing", "Mustering",
  "Noodling", "Percolating", "Perusing", "Philosophising", "Pondering", "Pontificating",
  "Processing", "Proofing", "Puttering", "Puzzling", "Reticulating", "Riffing",
  "Ruminating", "Scheming", "Schlepping", "Shucking", "Simmering", "Smooshing",
  "Spelunking", "Stewing", "Sussing", "Synthesizing", "Tinkering", "Transmuting",
  "Twiddling", "Vibing", "Whirring", "Wibbling", "Wizarding", "Working", "Wrangling",
}
local FLAVOR_DONE = {
  "Accomplished", "Actioned", "Actualized", "Baked", "Befuddled", "Boggled",
  "Boondoggled", "Booped", "Brewed", "Calculated", "Cerebrated", "Channelled",
  "Churned", "Clauded", "Coalesced", "Cogitated", "Combobulated", "Computed",
  "Concocted", "Conjured", "Considered", "Cooked", "Crafted", "Created",
  "Crunched", "Deliberated", "Determined", "Discombobulated", "Done", "Doodled",
  "Effected", "Elucidated", "Enchanted", "Envisioned", "Finagled", "Forged",
  "Formed", "Frolicked", "Galloped", "Generated", "Germinated", "Hatched",
  "Herded", "Honked", "Hustled", "Hyperspaced", "Ideated", "Imagined",
  "Incubated", "Inferred", "Jazzed", "Jived", "Levitated", "Manifested",
  "Marinated", "Meandered", "Moseyed", "Mulled", "Mused", "Mustered",
  "Noodled", "Percolated", "Perused", "Philosophised", "Pondered", "Pontificated",
  "Processed", "Proofed", "Puttered", "Puzzled", "Reticulated", "Riffed",
  "Ruminated", "Schemed", "Schlepped", "Shucked", "Simmered", "Smooshed",
  "Spelunked", "Stewed", "Sussed", "Synthesized", "Tinkered", "Transmuted",
  "Twiddled", "Vibed", "Whirred", "Wibbled", "Wizarded", "Worked", "Wrangled",
}

-- ─── In-body "typing" placeholder (compute dead-band filler) ──────────────────
--
-- The felt post-request gap is the model's COMPUTE dead bands — message_start →
-- first content block (~4s TTFT) and the gap after a tool_result while it
-- formulates the next message — where NOTHING streams. The bottom spinner hint
-- alone (virt_text) leaves the transcript BODY blank there, which reads as frozen.
-- This paints a single ANIMATED real buffer line IN the transcript flow so the
-- body reads active. It is NOT a client trick to shorten the gap — it just fills
-- the dead air. The styled block REPLACES it: every content-appending dispatch
-- branch calls remove_typing_ph() before rendering, so the placeholder (always the
-- LAST line while present) can never sit above real content. The tick re-adds it
-- during the next dead band (e.g. after a tool result), so post-tool gaps fill too.
local PH_FRAMES = { "●∙∙", "∙●∙", "∙∙●", "∙●∙" }

-- The activity WORD is the current phase: "Thinking" while the model streams a
-- thinking block, otherwise "Typing" (composing/emitting the reply). A tool run
-- shows its own cornered block instead (see in_typing_phase), so the word only
-- ever covers the two block-less compute phases.
local function activity_word()
  -- While the executor is blocked on the advisor (server_tool_use advisor sent, no
  -- advisor_tool_result yet), the compute phase IS the consult — say so. Checked
  -- first so it wins over a concurrent thinking block.
  if state.advisor_pending then return "Consulting" end
  if state.think_start then return "Thinking" end
  return "Typing"
end

-- The animated line text: pulsing dot + phase word (no seconds — the eol
-- randomizer below carries the climbing timer, so a second one here is redundant).
-- The dot frame advances on wall-clock time (~350ms) so the pulse is calm and
-- independent of the 110ms braille tick.
local function typing_ph_line()
  local frame = PH_FRAMES[(math.floor(vim.loop.now() / 350) % #PH_FRAMES) + 1]
  -- While advising, nest the activity line under the "● Advising using <model>"
  -- header with a `└` connector so it reads as "the consult is what's running".
  if state.advisor_pending then
    return string.format("  └ %s %s", frame, activity_word())
  end
  return string.format("%s %s", frame, activity_word())
end

-- The activity line shows during the two block-less compute phases (Typing +
-- Thinking) — NOT while a tool runs (its cornered ●/└ block IS the activity),
-- and not while a permission card or a pending diff owns the panel.
local function in_typing_phase()
  return state.working
    and not state.tool_run
    and not state.perm and not state.diff_pending
end

-- Delete the activity block. Safe to call anytime: no-op unless active. It is
-- always added as the LAST TWO lines (word + a trailing blank the eol randomizer
-- anchors to) and nothing appends while active (every appender removes it first),
-- so the last two lines ARE the block.
local function remove_typing_ph()
  if not state.typing_ph then return end
  state.typing_ph = false
  local buf = state.panel_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  local n = vim.api.nvim_buf_line_count(buf)
  if n < 2 then return end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, n - 2, n, false, {})
  vim.bo[buf].modifiable = false
end
mod._remove_typing_ph = remove_typing_ph
mod._activity_word    = activity_word

-- Append the activity block: the word line + a trailing BLANK line. The blank is
-- what set_hint anchors the eol randomizer to, so the randomizer renders on its
-- OWN row directly BELOW the activity word (stacked, no same-row jam). buf_append
-- auto-follows into view; the flag is set AFTER so a later append removes it.
local function add_typing_ph()
  if state.typing_ph then return end
  -- While advising, drop the "● Advising …" header's trailing blank first so the
  -- nested `└ Consulting` line attaches DIRECTLY under it (no gap breaking the
  -- connector). The activity block's own trailing blank still anchors the eol
  -- randomizer below. When advice arrives, render_advisor_result's body strips as
  -- usual, so nothing double-counts.
  if state.advisor_pending then
    local buf = state.panel_buf
    if buf and vim.api.nvim_buf_is_valid(buf) then
      local n = vim.api.nvim_buf_line_count(buf)
      if n > 0 and vim.api.nvim_buf_get_lines(buf, n - 1, n, false)[1] == "" then
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, n - 1, n, false, {})
        vim.bo[buf].modifiable = false
      end
    end
  end
  buf_append({ typing_ph_line(), "" })
  local n = vim.api.nvim_buf_line_count(state.panel_buf)
  hl_lines(n - 2, n - 2, "ClaudeDim")   -- the word line; the blank stays unpainted
  state.typing_ph = true
end

-- Rewrite the word line in place (advance the pulse), leaving the trailing blank.
local function update_typing_ph()
  if not state.typing_ph then return end
  local buf = state.panel_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  local n = vim.api.nvim_buf_line_count(buf)
  if n < 2 then return end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, n - 2, n - 1, false, { typing_ph_line() })
  vim.bo[buf].modifiable = false
  hl_lines(n - 2, n - 2, "ClaudeDim")
end

-- Driven by start_spinner + the 110ms tick: show/animate the placeholder in the
-- typing phase, drop it otherwise. Idempotent — safe to call every tick.
local function tick_typing_ph()
  if in_typing_phase() then
    if state.typing_ph then update_typing_ph() else add_typing_ph() end
  else
    remove_typing_ph()
  end
end

-- The eol randomizer hint: the per-turn flavour word + a climbing turn timer +
-- token count. It rides at EOL on the row BELOW the in-body activity line (the
-- trailing blank add_typing_ph anchors it to), so the two stack:
--   ●∙∙ Typing
--   ⣾ Catapulting… [42s · ↓ 632 tokens]
-- The phase (Typing / Thinking / a tool) shows ONCE — on the activity line or the
-- cornered ●/└ tool block — never duplicated here. The 110ms tick re-renders so
-- the timer climbs in place.
local function spinner_label()
  local frame = SPINNER[spin_i]
  -- turn_t0 is set once at dispatch and never re-baselined, so the timer climbs
  -- continuously across every phase (like the official TUI's "42s") and no gap —
  -- including the post-tool model round-trip — ever looks frozen. The flavour word
  -- stays the PRIMARY verb the whole turn (set once at dispatch).
  local word    = state.flavor_word or "Working"
  local elapsed = fmt_think_dur(core.turn_elapsed_ms())
  local parts   = { elapsed }
  -- The PHASE word (thinking / typing / a tool label) is NO LONGER in the bracket:
  -- the phase now shows exactly once, either as the in-body activity line
  -- (●∙∙ Typing / Thinking) or as the cornered ●/└ tool block. Duplicating it in
  -- the bracket was the redundancy the user asked to cut. The bracket keeps only
  -- the climbing turn timer + the token count when one exists (thinking).
  if type(state.think_tokens) == "number" and state.think_tokens > 0 then
    parts[#parts + 1] = string.format("↓ %d tokens", state.think_tokens)
  end
  -- "\n" puts the interrupt hint on its OWN line (set_hint splits on newlines):
  -- the status word can be long and eol virtual text never soft-wraps, so keeping
  -- "<Esc> to interrupt" inline pushed it off the right edge of a narrow panel.
  return string.format("%s %s… [%s]\n<Esc> to interrupt", frame, word, table.concat(parts, " · "))
end
mod._spinner_label = spinner_label

-- A user-decision modal is up and the CLI is blocked on the user: the permission
-- card, the pre-write edit gate, the AskUserQuestion card, or the diff-review
-- card. While any is up the turn timer must FREEZE (the wait isn't the model's
-- work) and the spinner reads "Waiting…" — matching the official TUI which pauses
-- its clock until the user acts. diff_pending rides along: an open unreviewed
-- vimdiff is the same "your decision needed" state even without a float card.
local function gated()
  return state.perm ~= nil or state.prewrite ~= nil or state.qask ~= nil
    or state.diff_card ~= nil or state.diff_pending == true
end
mod._gated = gated

-- The frozen "Waiting…" hint shown in place of the climbing spinner while a
-- decision modal owns the panel. The braille frame still animates so the panel
-- reads alive, but NO timer — the clock is paused (see turn_elapsed_ms).
local function waiting_label()
  return string.format("%s Waiting…\n<Esc> to interrupt", SPINNER[spin_i])
end

local function stop_spinner()
  if state.spin_timer then
    vim.fn.timer_stop(state.spin_timer)
    state.spin_timer = nil
  end
  -- Turn end / interrupt / reset all route through here — the compose gap is over,
  -- so drop the in-body placeholder too (it must not outlive the turn).
  remove_typing_ph()
  -- Drop the live phase indicators so a "Thinking…"/"Running…" label can't outlive
  -- the spinner (turn end / interrupt / reset all route through here). Safe because
  -- start_spinner's own stop_spinner call only fires between turns, never mid-phase.
  state.think_start = nil
  state.think_idx   = nil
  state.tool_run    = nil
  -- Safety net: the advisor-pending word/indent must never outlive the turn (e.g. an
  -- upstream advisor error that emits no advisor_tool_result). render_advisor_result
  -- clears it on the normal path; this catches turn-end/interrupt/reset.
  state.advisor_pending = nil
end

local function start_spinner()
  stop_spinner()
  spin_i = 1
  -- Paint the placeholder BEFORE the hint so set_hint anchors its virt_text to the
  -- placeholder (the new last line), not the line above it.
  tick_typing_ph()
  set_hint(spinner_label(), "ClaudeInput")
  render_queue()
  state.spin_timer = vim.fn.timer_start(110, function()
    if not state.working then stop_spinner(); return end
    spin_i = spin_i % #SPINNER + 1
    if gated() then
      -- A decision modal owns the panel: pause the turn clock and show a frozen
      -- "Waiting…" hint. Don't clobber the body with the typing placeholder — the
      -- modal float is the active surface.
      core.pause_turn()
      remove_typing_ph()
      set_hint(waiting_label(), "ClaudeInput")
      return
    end
    -- Not (any longer) gated: fold the just-ended pause into the accumulated total
    -- so the resumed timer excludes the wait, then resume the normal spinner.
    core.resume_turn()
    tick_typing_ph()
    set_hint(spinner_label(), "ClaudeInput")
    -- Re-anchor the queue to the (now lower) last line as output streams in.
    render_queue()
  end, { ["repeat"] = -1 })
end

-- ─── Render functions → claude/render.lua (Goal 15.7) ───────────────────────
-- render_prose / render_user / render_thinking / render_tool + the tool_result
-- foundation (build_collapsed/build_expanded/apply_line_hls/tool_result_lines) +
-- the search renderers + expand_result + render_result + _foldtext moved to
-- claude/render.lua. Init re-exports mod.expand_result / mod._foldtext below and
-- feeds render.render_user into process.wire{}.

-- Logo glyphs — must match ingest.py _show_banner (lines 580–582) exactly.
-- Each block element is a 3-byte UTF-8 char; the byte lengths are hardcoded
-- below for the highlight ranges (they never change).
--   G1 " ▐▛███▜▌"  — top of the head   (display width 8, 22 bytes)
--   G2 "▝▜█████▛▘" — belly             (display width 9, 27 bytes)
--   G3 "  ▘▘ ▝▝"   — feet              (display width 7, 15 bytes)
local BANNER_G1 = " ▐▛███▜▌"
local BANNER_G2 = "▝▜█████▛▘"
local BANNER_G3 = "  ▘▘ ▝▝"
-- Per-line right padding so the sidebar text starts at the SAME column on all
-- three lines despite the glyphs having different display widths (8/9/7 → all
-- align to column 11, matching ingest.py's "   "/"  "/"    " spacing).
local BANNER_P1 = "   "   -- 8 + 3 = 11
local BANNER_P2 = "  "    -- 9 + 2 = 11
local BANNER_P3 = "    "  -- 7 + 4 = 11

-- Blank padding line(s) above the glyph so the icon isn't flush against the top
-- window edge. All banner line indices below are expressed relative to this pad.
local BANNER_PAD = 1
local BANNER_L0  = BANNER_PAD        -- "Claude Code v…" / glyph row 1
local BANNER_L1  = BANNER_PAD + 1    -- model           / glyph row 2
local BANNER_L2  = BANNER_PAD + 2    -- cwd             / glyph row 3
local BANNER_SEP = BANNER_PAD + 3    -- separator underline

-- Render the three-line Claude logo banner on cold start.
--
-- Each line has mixed coloring: logo glyph in ClaudeHeader (clay #D97757) and
-- sidebar text in ClaudeProse (orange #F4A261). We apply ClaudeHeader first to
-- the whole line, then override the text byte-range with ClaudeProse (last
-- highlight wins for overlapping ranges at the same priority).
--
-- Sidebar text (matches ingest.py exactly):
--   line 0  "Claude Code v<version>"
--   line 1  "<friendly model>"        — filled by system/init when model known
--   line 2  "<cwd>"                    — the project root the session runs in
local function render_banner(model, version, cwd)
  local ver = (version and version ~= "") and (" v" .. version) or ""

  -- Top pad blank line(s) keep the icon off the window's top edge.
  local lines = {}
  for _ = 1, BANNER_PAD do lines[#lines + 1] = "" end
  lines[#lines + 1] = BANNER_G1 .. BANNER_P1 .. "Claude Code" .. ver
  lines[#lines + 1] = BANNER_G2 .. BANNER_P2 .. friendly_model(model)
  lines[#lines + 1] = BANNER_G3 .. BANNER_P3 .. (cwd or "")
  lines[#lines + 1] = sep_line()
  lines[#lines + 1] = ""   -- breathing room: the cursor rests here, not on the
                           -- separator, so it never blanks the orange divider.

  -- Replace the entire buffer so the banner always starts at line 0.
  local buf = state.panel_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  -- Glyph in ClaudeHeader (clay) across the three glyph rows + the separator.
  hl_lines(BANNER_L0, BANNER_SEP, "ClaudeHeader")

  -- Override sidebar text on the three glyph lines, each a distinct colour
  -- (KOS-style): "Claude Code" prose + dim version, model line, path line.
  local t0 = #BANNER_G1 + #BANNER_P1                                -- 25
  hl_range(BANNER_L0, t0,      -1, "ClaudeProse")
  hl_range(BANNER_L0, t0 + 11, -1, "ClaudeDim")                     -- version
  hl_range(BANNER_L1, #BANNER_G2 + #BANNER_P2, -1, "ClaudeModel")   -- 29
  hl_range(BANNER_L2, #BANNER_G3 + #BANNER_P3, -1, "ClaudePath")    -- 19
end

-- Fill the pre-rendered banner's version (line 0) + model (line 1) in place once
-- system/init reports them (the banner is drawn at panel open with the cwd but no
-- model/version — those only arrive in system/init). Wired into render.dispatch
-- (Render.wire.patch_banner) so the BANNER_* constants + this buffer-patch stay
-- in init with the rest of the banner code; render passes the already-friendly
-- model + the raw version string. `model`/`raw_ver` "" skip their line.
local function patch_banner(model, raw_ver)
  local ver = (raw_ver and raw_ver ~= "") and (" v" .. raw_ver) or ""
  local buf = state.panel_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)
      and vim.api.nvim_buf_line_count(buf) > BANNER_L1) then return end
  vim.bo[buf].modifiable = true
  if ver ~= "" then
    vim.api.nvim_buf_set_lines(buf, BANNER_L0, BANNER_L0 + 1, false,
      { BANNER_G1 .. BANNER_P1 .. "Claude Code" .. ver })
  end
  if model ~= "" then
    vim.api.nvim_buf_set_lines(buf, BANNER_L1, BANNER_L1 + 1, false,
      { BANNER_G2 .. BANNER_P2 .. model })
  end
  vim.bo[buf].modifiable = false
  if ver ~= "" then
    local t0 = #BANNER_G1 + #BANNER_P1
    hl_range(BANNER_L0, 0,       #BANNER_G1, "ClaudeHeader")
    hl_range(BANNER_L0, t0,      -1,         "ClaudeProse")
    hl_range(BANNER_L0, t0 + 11, -1,         "ClaudeDim")
  end
  if model ~= "" then
    hl_range(BANNER_L1, 0,                       #BANNER_G2, "ClaudeHeader")
    hl_range(BANNER_L1, #BANNER_G2 + #BANNER_P2, -1,         "ClaudeModel")
  end
end

-- Rewrite just the banner's cwd line in place. Called on DirChanged so the path
-- always reflects the directory the user is in, without redrawing the whole
-- banner (which would wipe the rendered conversation).
local function update_banner_cwd(cwd)
  local buf = state.panel_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  if vim.api.nvim_buf_line_count(buf) <= BANNER_L2 then return end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, BANNER_L2, BANNER_L2 + 1, false,
    { BANNER_G3 .. BANNER_P3 .. (cwd or "") })
  vim.bo[buf].modifiable = false
  hl_range(BANNER_L2, 0,                       #BANNER_G3, "ClaudeHeader")
  hl_range(BANNER_L2, #BANNER_G3 + #BANNER_P3, -1,         "ClaudePath")
end

-- Rewrite just the banner's model line in place (line 1). Called by the model
-- picker so the chosen model shows immediately, without redrawing the banner.
-- `friendly` is the already-friendly display name (or "" to blank the line).
local function update_banner_model(friendly)
  local buf = state.panel_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  if vim.api.nvim_buf_line_count(buf) <= BANNER_L1 then return end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, BANNER_L1, BANNER_L1 + 1, false,
    { BANNER_G2 .. BANNER_P2 .. (friendly or "") })
  vim.bo[buf].modifiable = false
  hl_range(BANNER_L1, 0,                       #BANNER_G2, "ClaudeHeader")
  hl_range(BANNER_L1, #BANNER_G2 + #BANNER_P2, -1,         "ClaudeModel")
end

-- Rewrite every separator line (a line made entirely of "─") to the current
-- panel width so the orange dividers shrink/extend with the window instead of
-- wrapping to the next line. Called on resize.
local function refit_separators()
  local buf = state.panel_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  local new   = sep_line()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  vim.bo[buf].modifiable = true
  for i, l in ipairs(lines) do
    -- all-dashes test: stripping every "─" leaves nothing (byte-safe, unlike a
    -- multibyte Lua pattern with "+").
    if l ~= "" and (l:gsub("─", "")) == "" and l ~= new then
      vim.api.nvim_buf_set_lines(buf, i - 1, i, false, { new })
      vim.api.nvim_buf_add_highlight(buf, -1, "ClaudeHeader", i - 1, 0, -1)
    end
  end
  vim.bo[buf].modifiable = false
end

-- ─── Wire the render/dispatch module (Goal 15.7) ─────────────────────────────
-- render.lua owns the renderers + dispatch but reaches back into init's spinner/
-- hint/typing-placeholder/pad/banner machinery (all timer- or window-coupled, so
-- it stays here). Inject those + the FLAVOR_DONE table; maybe_send_next comes from
-- the process module; patch_banner is init's banner buffer-patch. This is placed
-- after every dep (incl. patch_banner just above) is defined.
render.wire({
  set_hint         = set_hint,
  clear_hint       = clear_hint,
  stop_spinner     = stop_spinner,
  remove_typing_ph = remove_typing_ph,
  reanchor_pad     = reanchor_pad,
  friendly_model   = friendly_model,
  fmt_think_dur    = fmt_think_dur,
  FLAVOR_DONE      = FLAVOR_DONE,
  maybe_send_next  = process.maybe_send_next,
  patch_banner     = patch_banner,
})

-- Re-export the render module's mod._* / public hooks (the <C-o> keymap calls
-- mod.expand_result; the window foldtext expr calls mod._foldtext).
mod.expand_result = render.expand_result
mod._foldtext     = render._foldtext

-- Post-approval edit hunk (Goal 14.4): claude_diff calls this after an accepted
-- edit to drop the numbered red/green block into the transcript.
mod.render_edit_block = render.render_edit_hunk

-- ─── Stream-json event dispatcher (Goal 6.3) ──────────────────────────────────

-- Reply to a can_use_tool control_request over stdin (the permission gate).
-- `decision` is "allow" or "deny". The SDK contract requires us to echo the
-- request's `input` back as `updatedInput` on allow (the CLI re-validates against
-- it); on an "allow always" we additionally pass `updatedPermissions` (the
-- request's permission_suggestions) so the rule persists to localSettings and the
-- tool won't prompt again. Mirrors mod.interrupt's control_response wire shape.
-- `o.input` is the decoded request.input table; an empty table must encode as a
-- JSON object ({}), not an array ([]) — hence the empty_dict guard.
-- Full wire shapes: .work/FINDINGS.md § Q-PERM. Reused by the step-4 card UI.
-- ─── Permission / pre-write gate + diff-review card (Goal 15.5) ───────────────
-- The permission card, pre-write edit gate, diff-review card, and the shared
-- SW-anchored panel-float helpers moved to claude/gate.lua. Inject init-owned
-- spinner/hint/float helpers (prompt_input as a thunk since mod.prompt_input is
-- defined further down; float_bottom_row is widgets'). Then re-source the geometry
-- helpers + send_permission_response back out so the widgets.wire{}/question.wire{}
-- calls below forward them on — that indirection is why widgets.lua/question.lua
-- stay untouched by this move.
gate.wire({
  start_spinner    = start_spinner,
  stop_spinner     = stop_spinner,
  clear_hint       = clear_hint,
  prompt_input     = function() mod.prompt_input() end,
  float_bottom_row = widgets.float_bottom_row,
  -- Reserve transcript space under the perm / diff cards so live output (and the
  -- "Waiting…" hint) sits ABOVE the card instead of peeking below it — same pad
  -- contract the question card + chat bar use.
  set_bottom_pad   = set_bottom_pad,
  clear_bottom_pad = clear_bottom_pad,
  -- Paint the frozen "Waiting…" hint when the permission card stops the spinner
  -- (the diff/prewrite/question gates keep the spinner running, so their tick
  -- shows it directly — this covers the one gate that halts the tick).
  set_waiting_hint = function() set_hint(waiting_label(), "ClaudeInput") end,
})

-- Re-source the gate helpers init still calls directly (event dispatcher, chat bar)
-- plus the geometry/permission helpers the widget/question wire calls forward below.
-- NOTE: try_prewrite_gate / show_permission_card / EDIT_TOOLS / GATED_EDIT_TOOLS
-- are no longer re-sourced here — their only init consumer was dispatch, which
-- moved to claude/render.lua (15.7) and now calls gate.* directly.
local send_permission_response  = gate.send_permission_response
local resolve_permission        = gate.resolve_permission
local panel_float_geom          = gate.panel_float_geom
local harden_float_scroll       = gate.harden_float_scroll
local attach_panel_float_resize = gate.attach_panel_float_resize
local show_diff_card            = gate.show_diff_card
local close_diff_card           = gate.close_diff_card

-- Re-export the gate's test hooks (the specs reference mod._*) + the public
-- on_prewrite_resolve (claude_diff calls it in prewrite mode).
mod.on_prewrite_resolve       = gate.on_prewrite_resolve
mod._send_permission_response = gate.send_permission_response
mod._reconstruct_edit         = gate.reconstruct_edit
mod._move_perm_choice         = gate.move_perm_choice
mod._resolve_permission       = gate.resolve_permission
mod._close_diff_card          = gate.close_diff_card
mod._resolve_diff_card        = gate.resolve_diff_card
mod._show_diff_card           = gate.show_diff_card

-- Inject init's float/pad helpers into the widgets module (claude/widgets.lua owns
-- the Task-plan card but must place it against the panel column + reserve transcript
-- space). The geometry helpers now come from gate (re-sourced above); set_bottom_pad
-- is init-owned. Only these source values changed when 15.5 re-homed the helpers.
widgets.wire({
  set_bottom_pad      = set_bottom_pad,
  panel_float_geom    = panel_float_geom,
  harden_float_scroll = harden_float_scroll,
})

-- Test hooks for the widget module (re-exported so the specs' mod._* references
-- resolve; they moved to claude/widgets.lua in the Goal 15.3 extraction).
mod._render_todo_lines = widgets.render_todo_lines
mod._plan_complete     = widgets.plan_complete
mod._apply_task_tool   = widgets.apply_task_tool

-- ─── Slash-command menu ───────────────────────────────────────────────────────
-- The chat bar's "/" command menu (claude/slash.lua). Injects the same two
-- init-owned float helpers the other floats use; the menu floats above the bar.
slash.wire({
  panel_float_geom    = panel_float_geom,
  harden_float_scroll = harden_float_scroll,
})
mod._slash = slash   -- test hook

-- ─── Effort slider (/effort) ──────────────────────────────────────────────────
-- The reasoning-effort modal (claude/effort.lua). Same float helpers as the slash
-- menu; confirming respawns the process with the new --effort (see mod.pick_effort).
effort.wire({
  panel_float_geom    = panel_float_geom,
  harden_float_scroll = harden_float_scroll,
})
mod._effort = effort   -- test hook

-- ─── Advisor picker (/advisor) ────────────────────────────────────────────────
-- The advisor-model modal (claude/advisor.lua). Same float helpers as the effort
-- slider; confirming applies the advisor LIVE via apply_flag_settings (no respawn,
-- so context is preserved — unlike the /effort and /model respawns).
advisor.wire({
  panel_float_geom    = panel_float_geom,
  harden_float_scroll = harden_float_scroll,
})
mod._advisor = advisor   -- test hook

-- ─── Question card (AskUserQuestion) ──────────────────────────────────────────
-- The AskUserQuestion card moved to claude/question.lua (Goal 15.4). It reaches
-- back into init's float/pad/spinner/permission machinery — inject those helpers
-- (prompt_input as a thunk since mod.prompt_input is defined further down). When
-- 15.5 re-homes the float+permission helpers to claude/gate.lua, only the sources
-- on the right-hand side change here; question.lua stays untouched.
question.wire({
  send_permission_response  = send_permission_response,
  panel_float_geom          = panel_float_geom,
  harden_float_scroll       = harden_float_scroll,
  attach_panel_float_resize = attach_panel_float_resize,
  set_bottom_pad            = set_bottom_pad,
  clear_bottom_pad          = clear_bottom_pad,
  start_spinner             = start_spinner,
  stop_spinner              = stop_spinner,
  clear_hint                = clear_hint,
  prompt_input              = function() mod.prompt_input() end,
  set_waiting_hint          = function() set_hint(waiting_label(), "ClaudeInput") end,
})
-- Re-export the question card's test hooks so the `mod._question*` spec references
-- resolve; they moved to claude/question.lua (Goal 15.4). The dispatch call site
-- (show_question_card) moved to claude/render.lua (15.7) and calls question.* direct.
mod._show_question_card                = question.show_question_card
mod._move_question_choice              = question.move_question_choice
mod._next_question                     = question.next_question
mod._prev_question                     = question.prev_question
mod._toggle_question_choice            = question.toggle_question_choice
mod._cancel_question                   = question.cancel_question
mod._respond_to_claude_question        = question.respond_to_claude_question
mod._set_question_custom               = question.set_question_custom
mod._select_question_choice            = question.select_question_choice


-- ─── Stream-json event dispatcher → claude/render.lua (Goal 15.7) ───────────
-- dispatch(event) + all render_* branch targets + the tool_result foundation +
-- the search renderers moved to claude/render.lua. It is wired above (render.wire)
-- and fed by process.on_stdout (process.wire.dispatch = render.dispatch).

-- ─── Panel buffer setup ───────────────────────────────────────────────────────

-- Create (or reuse) the panel scratch buffer. Called by toggle() before opening
-- the panel window. Idempotent: if the buffer already exists and is valid,
-- returns it immediately so the scrollback survives panel close/reopen within
-- the same session. reset() deletes the buffer explicitly to start blank.
local function ensure_panel_buf()
  if state.panel_buf and vim.api.nvim_buf_is_valid(state.panel_buf) then
    return state.panel_buf
  end

  local buf = vim.api.nvim_create_buf(false, true)   -- unlisted, scratch
  vim.bo[buf].buftype    = "nofile"
  vim.bo[buf].bufhidden  = "hide"   -- don't wipe on window close; keep scrollback
  vim.bo[buf].swapfile   = false
  vim.bo[buf].modifiable = false    -- prevent accidental edits; toggled by buf_append
  -- filetype "claude" is the hook the modal statusline keys off (lua/plugins/ui.lua
  -- in_claude): when this buffer is focused, lualine shows CLAUDE / CODE instead of
  -- the plain Neovim mode. The reply float buffer gets the same filetype so the
  -- modal indicator persists while typing.
  vim.bo[buf].filetype   = "claude"
  -- foldmethod is window-local, not buffer-local; set it in open_panel_window.
  -- Name the buffer "claude" so bufferline and lualine show something readable
  -- instead of "[No Name]". pcall guards the rare E95 name-collision.
  pcall(vim.api.nvim_buf_set_name, buf, "claude")

  state.panel_buf = buf
  state.hint_ns   = vim.api.nvim_create_namespace("claude_hint")
  state.queue_ns  = vim.api.nvim_create_namespace("claude_queue")
  state.pad_ns    = vim.api.nvim_create_namespace("claude_pad")
  state.folds     = {}
  process.clear_stdout()
  return buf
end

-- ─── Panel buffer keymaps ─────────────────────────────────────────────────────

-- Remap insert-mode triggers to open the reply float instead of editing.
--
-- Why remap rather than ignore?
--   The buffer is nomodifiable, so i/a/o/CR would normally throw E21 ("cannot
--   make changes"). An E21 in the middle of a conversation is jarring. The
--   remaps intercept all natural "I want to type something" gestures and route
--   them to prompt_input(), which is exactly what the user intends.
--
-- Why not remap in the plugin spec keys table?
--   keys-table keymaps are global. These must be buffer-local (active only
--   when cursor is in the claude panel) to avoid clobbering i/a/o globally.
local function set_panel_keymaps(buf)
  local function open_input()
    mod.prompt_input()
  end
  for _, key in ipairs({ "i", "a", "o" }) do
    vim.keymap.set("n", key, open_input, {
      buffer  = buf,
      noremap = true,
      silent  = true,
      desc    = "Claude: open reply float",
    })
  end
  -- <CR> confirms the active permission choice when a card is up; otherwise it
  -- opens the reply float (same as i/a/o).
  vim.keymap.set("n", "<CR>", function()
    if state.perm then
      resolve_permission(state.perm.options[state.perm.choice].kind)
    else
      open_input()
    end
  end, {
    buffer  = buf,
    noremap = true,
    silent  = true,
    desc    = "Claude: reply / confirm permission",
  })
  -- <Esc> rejects the pending permission when a card is up; otherwise it
  -- interrupts the current turn (control_request) while keeping the session
  -- alive. Matches the Claude Code TUI's Esc behaviour.
  vim.keymap.set("n", "<Esc>", function()
    if state.perm then
      resolve_permission("deny")
    else
      mod.interrupt()
    end
  end, {
    buffer  = buf,
    noremap = true,
    silent  = true,
    desc    = "Claude: interrupt current turn",
  })

  -- Mouse: clicking a "Thought" fold toggles it open/closed. <LeftRelease> fires
  -- AFTER the default <LeftMouse> has positioned the cursor, so the line under the
  -- cursor is the clicked row — and for a closed fold that row is its start line
  -- (the literal "▼ Thought" header), so the same match works in both states.
  -- Clicks elsewhere (prose, code, thinking body when expanded) fall through.
  vim.keymap.set("n", "<LeftRelease>", function()
    local lnum = vim.fn.line(".")
    local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
    if line:match("^▼ Thought") then
      pcall(vim.cmd, "normal! za")
      -- A pad (question card / chat bar) may be reserved; expanding the fold pushes
      -- the last line down under it. Re-anchor so existing output stays above.
      reanchor_pad()
    end
  end, {
    buffer  = buf,
    noremap = true,
    silent  = true,
    desc    = "Claude: toggle thinking fold on click",
  })

  -- Keyboard fold toggle: same re-anchor as the mouse path. `normal! za` uses the
  -- non-remapped default toggle (no recursion); reanchor_pad lifts the last line
  -- back above any reserved pad when the fold's height change moved it.
  vim.keymap.set("n", "za", function()
    pcall(vim.cmd, "normal! za")
    reanchor_pad()
  end, {
    buffer  = buf,
    noremap = true,
    silent  = true,
    desc    = "Claude: toggle fold + re-anchor pad",
  })

  -- Expand a collapsed tool_result block under the cursor. <C-o> is Neovim's
  -- default jumplist jump, but this read-only transcript never uses the jumplist,
  -- so overriding it BUFFER-LOCALLY (panel only) is free and matches the CC TUI's
  -- "ctrl+o to expand" affordance. No-op when no collapsed block is near.
  vim.keymap.set("n", "<C-o>", function()
    mod.expand_result()
  end, {
    buffer  = buf,
    noremap = true,
    silent  = true,
    desc    = "Claude: expand tool_result under cursor",
  })

  -- Subagent switcher (17.3): ↑/↓ move the selection while the switcher bar is
  -- shown; when it isn't, fall through to normal cursor motion (feedkeys with the
  -- "n" noremap flag, so no recursion). <CR> opens the selected subagent's drill-in
  -- view (or returns to main on the "main" row). These only act when subagents
  -- exist, so the panel's normal read behaviour is unchanged the rest of the time.
  local function nav_or_default(delta, key)
    if not widgets.subagent_nav(delta) then
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "n", false)
    end
  end
  vim.keymap.set("n", "<Up>",   function() nav_or_default(-1, "<Up>")   end,
    { buffer = buf, noremap = true, silent = true, desc = "Claude: subagent switcher up" })
  vim.keymap.set("n", "<Down>", function() nav_or_default(1,  "<Down>") end,
    { buffer = buf, noremap = true, silent = true, desc = "Claude: subagent switcher down" })
  vim.keymap.set("n", "<CR>", function()
    widgets.subagent_enter()   -- no-op when no switcher; panel is otherwise read-only
  end, { buffer = buf, noremap = true, silent = true, desc = "Claude: open subagent view" })
end

-- ─── Persistent bidirectional subprocess (spawn + send) ──────────────────────
-- The subprocess lifecycle (build_args/panel_path/SEARCH_NUDGE + ensure_process/
-- stop_process/on_stdout/on_exit + dispatch_send/send/enqueue/maybe_send_next +
-- uuid4) moved to claude/process.lua (Goal 15.6). It reaches back into init's
-- render/spinner/hint machinery (dispatch is 15.7's; render_* + spinner + hint
-- hold timers / touch the render foundation) via process.wire{} — the call site
-- is below, after attach_host_context is defined (send needs it). Init re-sources
-- send/enqueue/maybe_send_next/stop_process/uuid4 there for the submit path,
-- teardown paths, and interrupt control_request.

-- ─── Open-buffer awareness (FINDINGS § Q-CTX) ────────────────────────────────

-- The real, on-disk file backing a window's buffer, or nil. Skips the panel,
-- floats (chat bar / cards), terminals, non-file UI buffers (alpha/NvimTree/the
-- panel itself), and unnamed or unsaved scratch buffers — none of which the CLI
-- could @-mention. Returns { path=<abs>, disp=<~/.-relative for display> }.
local function host_file_of(win)
  if not (win and vim.api.nvim_win_is_valid(win)) then return nil end
  if win == state.panel_win then return nil end
  if vim.api.nvim_win_get_config(win).relative ~= "" then return nil end     -- float
  local buf = vim.api.nvim_win_get_buf(win)
  if vim.bo[buf].buftype ~= "" then return nil end                           -- terminal/nofile
  local ft = vim.bo[buf].filetype
  if ft == "alpha" or ft == "NvimTree" or ft == "claude" then return nil end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then return nil end
  local abs = vim.fn.fnamemodify(name, ":p")
  if vim.fn.filereadable(abs) == 0 then return nil end                       -- unsaved/new
  return { path = abs, disp = vim.fn.fnamemodify(abs, ":~:.") }
end
mod._host_file_of = host_file_of

-- The file the user currently has open in the editor. Prefers a given window
-- (the pre-panel-open focus captured in toggle()), else scans the tabpage for
-- the first real-file window — the editor left of the panel.
local function current_host_file(prefer_win)
  local hf = prefer_win and host_file_of(prefer_win) or nil
  if hf then return hf end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    hf = host_file_of(w)
    if hf then return hf end
  end
  return nil
end
mod._current_host_file = current_host_file

-- Fold the open editor file into the WIRE text so Claude stays aware of it.
-- v2 (option A — token-efficient): a FULL @<abspath> mention only on the FIRST
-- turn for a file (and on a file SWITCH) — the CLI inlines the whole file with no
-- Read round-trip (verified: stream-json honours @-mentions, absolute paths
-- included — FINDINGS § Q-CTX). On REPEAT turns for the SAME file the content is
-- already in session history, so re-inlining every turn would bloat the context
-- window; instead a cheap plain-text path breadcrumb (NO @, so no re-inline) is
-- appended so a bare "this file" still resolves. Without the breadcrumb the model
-- loses the referent on turn 2+ and asks for the path (observed live 2026-07-06).
--
-- The LIVE editor file is resolved each send (current_host_file()); host_ctx_last_
-- path tracks the file last folded in, distinguishing "changed → full inline" from
-- "same → breadcrumb". NEUTRAL phrasing only — command-y text ("ignore … do not
-- use tools") trips the CLI's prompt-injection heuristic. Returns (wire_text,
-- note): note = the ~-relative display path ONLY on a full inline (first/changed),
-- for render_user's dim echo line; nil on a breadcrumb or no-op. The transcript
-- echo always stays the user's own text; only the wire carries the fold-in.
local function attach_host_context(text)
  if not state.host_ctx_enabled then return text, nil end
  -- Prefer the live editor file so a mid-session switch is picked up: the focused
  -- window first (a user reading a split), else the tabpage scan; fall back to the
  -- panel-open snapshot if no editor window is live. In a real send the panel float
  -- holds focus (host_file_of filters it out), so this resolves to the scan.
  local hf = current_host_file(vim.api.nvim_get_current_win()) or state.host_file
  if not hf then return text, nil end
  -- User already named the file themselves — nothing to fold in; mark it seen so a
  -- later bare "this file" gets a breadcrumb, not a fresh full inline. No note.
  if text:find(hf.path, 1, true) or text:find("@" .. hf.disp, 1, true) then
    state.host_ctx_last_path = hf.path
    return text, nil
  end
  local changed = hf.path ~= state.host_ctx_last_path
  state.host_ctx_last_path = hf.path
  if changed then
    -- First turn on this file (or a switch): full @<abspath> → CLI inlines it.
    return text .. "\n\n(For context, the file I currently have open in my editor: @"
      .. hf.path .. ")", hf.disp
  end
  -- Same file, repeat turn: cheap breadcrumb, no re-inline, no note.
  return text .. "\n\n(Still working in the file open in my editor: "
    .. hf.path .. ")", nil
end
mod._attach_host_context = attach_host_context

-- Persist the open-buffer-awareness on/off choice across nvim restarts. Stored
-- as a single "1"/"0" in stdpath('state') so a toggle survives closing Kodex
-- IDE until it is toggled back. Load is best-effort (missing file → default ON).
local host_ctx_pref_file = vim.fn.stdpath("state") .. "/kodex_claude_host_ctx"

local function save_host_ctx_pref(on)
  pcall(vim.fn.writefile, { on and "1" or "0" }, host_ctx_pref_file)
end

local function load_host_ctx_pref()
  local ok, lines = pcall(vim.fn.readfile, host_ctx_pref_file)
  if not ok or type(lines) ~= "table" or not lines[1] then return true end  -- default ON
  return lines[1] ~= "0"
end

-- Load the persisted preference at module init (overrides the state default).
state.host_ctx_enabled = load_host_ctx_pref()

-- Toggle open-buffer awareness on/off (<leader>cb) and remember it across
-- restarts. Off = the panel never injects the open file; on = @-mention on the
-- next send. host_ctx_last_path is cleared so re-enabling mid-session re-arms
-- injection for the current file.
function mod.toggle_host_ctx()
  state.host_ctx_enabled = not state.host_ctx_enabled
  state.host_ctx_last_path = nil
  save_host_ctx_pref(state.host_ctx_enabled)
  vim.notify(
    "Claude open-buffer context " .. (state.host_ctx_enabled and "ON" or "OFF")
      .. " (remembered across restarts)",
    vim.log.levels.INFO
  )
end

-- ─── Wire the subprocess module (Goal 15.6) ──────────────────────────────────
-- process.lua owns the subprocess lifecycle but reaches back into init's render/
-- spinner/hint machinery. Inject those here — this is the latest point where all
-- eleven dependencies are defined (attach_host_context, just above, is send's).
-- dispatch is still init's (15.7); render_* + spinner + hint stay because they
-- hold timers / touch the render foundation. claude_bin is the resolved binary.
process.wire({
  dispatch            = render.dispatch,      -- dispatch moved to render.lua (15.7)
  render_user         = render.render_user,   -- render_user moved to render.lua (15.7)
  render_queue        = render_queue,
  remove_typing_ph    = remove_typing_ph,
  start_spinner       = start_spinner,
  stop_spinner        = stop_spinner,
  clear_hint          = clear_hint,
  set_hint            = set_hint,
  attach_host_context = attach_host_context,
  FLAVOR              = FLAVOR,
  claude_bin          = mod.CLAUDE_BIN,
})

-- Re-source the process functions init still calls directly (submit path,
-- teardown paths, interrupt control_request) + re-export the specs' test hooks.
local send            = process.send
local enqueue         = process.enqueue
local stop_process    = process.stop_process
local uuid4           = process.uuid4
mod._send             = process.send
mod._maybe_send_next  = process.maybe_send_next
mod._stop_process     = process.stop_process

-- Public submit used by the input float: send immediately when idle, otherwise
-- queue (type-ahead while Claude is working, like the Claude Code TUI).
local function submit(text)
  -- Intercept the panel-local /effort command: "/effort <level>" applies directly,
  -- a bare "/effort" opens the slider. Never sent to the CLI as a message.
  local level = text:match("^/effort%s*(%S*)$")
  if level ~= nil then
    mod.pick_effort(level ~= "" and level or nil)
    return
  end
  -- Intercept the panel-local /advisor command: "/advisor <model>" applies directly,
  -- a bare "/advisor" opens the picker. Never sent to the CLI as a message.
  local adv = text:match("^/advisor%s*(%S*)$")
  if adv ~= nil then
    mod.pick_advisor(adv ~= "" and adv or nil)
    return
  end
  if state.working then
    enqueue(text)
  else
    send(text)
  end
end

-- ─── Chat input float (Goal 6.5) ─────────────────────────────────────────────

-- Open the reply input as a rounded floating bar anchored to the bottom of the
-- panel — the stylish chat bar.
--
-- Why a float, not a split?
--   A split adds a second per-window statusline between the panel and the input
--   (the stray "claude [-]" bar) and looks plain. The float keeps the rounded,
--   bordered look the user wants. The float carries filetype "claude" too, so its
--   own (active) lualine bar shows the modal CLAUDE … INSERT … CODE while typing;
--   the panel behind it falls back to the inactive_sections variant
--   (lua/plugins/ui.lua) — per-window bars, no shared global statusline.
--
-- The burn meters (5h / weekly / context) render INSIDE the box, on their own row
-- below the input (a virtual line), so the single rounded outline wraps both the
-- input and the meters. The bar's interior is the CursorLine gray (ClaudeBarBg) so
-- it reads flush. The newest output is kept visible above the bar by reserving its
-- footprint as bottom padding (set_bottom_pad); the over-scroll clamp adds that pad
-- so it doesn't fight the push-up.
local function open_chat_float(title, callback, opts)
  opts = opts or {}
  -- When persist_draft is set, the bar's unsent text survives a hide/show via
  -- state.chat_draft (see close()/submit below). Only the main "Reply" bar opts in.
  local persist_draft = opts.persist_draft == true
  -- Flipped true the instant a real submit fires, so close() knows NOT to re-save
  -- the (already-sent) text as a draft.
  local submitted = false
  -- Span the full panel width: left edge flush with the panel, width = panel minus
  -- the two border chars. Shared geometry helper (anchors to the panel's real
  -- screen column — same as the permission/question floats).
  local float_col, float_w = panel_float_geom()

  local ibuf = vim.api.nvim_create_buf(false, true)
  vim.bo[ibuf].buftype   = "prompt"   -- <CR> fires prompt_setcallback; no manual map needed
  vim.bo[ibuf].bufhidden = "wipe"
  vim.bo[ibuf].swapfile  = false
  -- Same filetype as the panel buffer so the modal statusline keys off it.
  vim.bo[ibuf].filetype  = "claude"

  -- Surface the active permission mode in the bar's title: "Plan Mode" when
  -- planning (read-only gate), "Build Mode" for the default (edits apply). Mirrors
  -- the border color (ClaudeBarBorderPlan vs ClaudeBarBorder) below.
  local mode_label = (state.permission_mode == "plan") and " - Plan Mode" or " - Build Mode"
  local label      = title .. mode_label
  local meter_ns = vim.api.nvim_create_namespace("claude_bar_meters")

  -- Render the meters as a virtual line attached below the LAST input line.
  -- Returns 1 if a meter row was drawn, 0 if there's no data. Re-called on resize
  -- and on every text change so the meters re-fit the width AND stay below the
  -- input. Anchoring to the last line (not line 0) is critical: a multi-line paste
  -- adds lines 1,2,3…, and a line-0 anchor would render the meters in the MIDDLE
  -- of the text — and scroll them off the top once the input grew past the view.
  local function render_meters()
    vim.api.nvim_buf_clear_namespace(ibuf, meter_ns, 0, -1)
    local m = require("utils.claude_burn").chunks(float_w)
    if not m then return 0 end
    local last = math.max(vim.api.nvim_buf_line_count(ibuf) - 1, 0)
    vim.api.nvim_buf_set_extmark(ibuf, meter_ns, last, 0, {
      virt_lines = { m }, virt_lines_above = false,
    })
    return 1
  end

  local win = vim.api.nvim_open_win(ibuf, true, {
    relative  = "editor",
    anchor    = "SW",
    row       = widgets.float_bottom_row(),
    col       = float_col,
    width     = float_w,
    height    = 1,                 -- grown to input rows + meter row below
    border    = "rounded",
    style     = "minimal",
    title     = " " .. label .. " ",
    title_pos = "left",
  })

  -- Flush surface: interior + border share the CursorLine gray (ClaudeBarBg /
  -- ClaudeBarBorder) so the rounded box reads as one solid bar against the panel,
  -- with only the clay (or plan-blue) outline standing out.
  local border_hl = (state.permission_mode == "plan") and "ClaudeBarBorderPlan" or "ClaudeBarBorder"
  vim.wo[win].winhighlight = "FloatBorder:" .. border_hl
    .. ",FloatTitle:" .. border_hl
    .. ",NormalFloat:ClaudeBarBg"

  -- Soft-wrap long input onto new lines (a growing paragraph) instead of scrolling
  -- horizontally off-screen. linebreak wraps at word boundaries.
  vim.wo[win].wrap      = true
  vim.wo[win].linebreak = true
  harden_float_scroll(win)   -- uniform with the permission/question floats (no over-scroll)

  -- Size the box to enclose the input rows PLUS the meter row, and reserve that
  -- footprint as panel bottom padding so the newest output rides just above the
  -- bar. Called on open, on input grow, and on resize.
  local MAX_INPUT_ROWS = 12
  local cur_rows       = 1
  local bar_h          = 1   -- last interior height (rows+meters); slash menu floats above bar_h+2
  local function apply_layout()
    if not vim.api.nvim_win_is_valid(win) then return end
    local mrows = render_meters()
    local h     = cur_rows + mrows
    bar_h = h
    local c     = vim.api.nvim_win_get_config(win)
    if c.height ~= h then
      c.height = h
      vim.api.nvim_win_set_config(win, c)
    end
    set_bottom_pad(h + 3)   -- h interior + 2 border + 1 blank separator row
  end

  local function fit_height_now()
    if not vim.api.nvim_win_is_valid(win) then return end
    local lines = vim.api.nvim_buf_get_lines(ibuf, 0, -1, false)
    local rows  = 0
    for _, l in ipairs(lines) do
      rows = rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(l) / float_w))
    end
    rows = math.min(math.max(rows, 1), MAX_INPUT_ROWS)
    if rows ~= cur_rows then
      cur_rows = rows
      apply_layout()           -- re-fits height AND re-anchors meters
    else
      render_meters()          -- height unchanged but the last line may have moved
    end
  end

  -- ── Slash-command menu driver ──────────────────────────────────────────────
  -- When the input line is "/<query>" (no space yet), pop the command menu above
  -- the bar and colour the typed span (valid prefix vs no-match). A space after
  -- the command, or any non-slash line, closes the menu. Runs on every text
  -- change, after fit_height_now (so bar_h is current).
  local slash_ns = vim.api.nvim_create_namespace("claude_slash_input")
  local function on_slash_accept()
    -- A command was inserted ("/name "): re-fit + keep the cursor typing in the bar.
    fit_height_now()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_set_current_win, win)
      vim.cmd("startinsert!")
    end
  end
  local function update_slash_menu()
    if not vim.api.nvim_buf_is_valid(ibuf) then return end
    vim.api.nvim_buf_clear_namespace(ibuf, slash_ns, 0, -1)
    local lnum = vim.api.nvim_buf_line_count(ibuf) - 1
    local line = vim.api.nvim_buf_get_lines(ibuf, lnum, lnum + 1, false)[1] or ""
    -- CRITICAL: a prompt buffer keeps the "❯ " prompt AS part of the buffer line
    -- (real typed line is "❯ /caveman", not "/caveman"), so strip the prompt before
    -- matching. prefix_len is where the typed text starts (the "/" byte column),
    -- used to anchor the colour extmark on the right span.
    local prompt = vim.fn.prompt_getprompt(ibuf) or ""
    local prefix_len = 0
    if prompt ~= "" and line:sub(1, #prompt) == prompt then
      prefix_len = #prompt
    end
    local typed = line:sub(prefix_len + 1)
    -- Only a leading "/" with no whitespace => still composing a command: drive the
    -- picker menu above the bar and colour the partial prefix while it still matches.
    local query = typed:match("^/([^%s]*)$")
    if query ~= nil then
      -- Menu floats just above the bar. Use the bar window's LIVE height (interior +
      -- 2 border) so the small gap stays constant regardless of the meter row / wrap
      -- growth — a stale tracked height put the menu a row too high.
      local bar_rows = bar_h + 2
      if vim.api.nvim_win_is_valid(win) then
        bar_rows = vim.api.nvim_win_get_config(win).height + 2
      end
      slash.open(ibuf, query, bar_rows, on_slash_accept)
      -- Colour the "/query" span clay ONLY while it's still a live command prefix;
      -- once the typed letters match nothing, leave it PLAIN (not red) — the
      -- highlight signals "this is a potential command", then drops off when it
      -- obviously isn't one anymore.
      if slash.has_prefix(query) then
        vim.api.nvim_buf_set_extmark(ibuf, slash_ns, lnum, prefix_len, {
          end_col = #line, hl_group = "ClaudeSlashMatch",
        })
      end
    else
      if slash.active() then slash.close() end
    end

    -- Anywhere-in-line highlight: colour every "/token" that is still a live command
    -- PREFIX, so a command typed mid-sentence or after args lights up as you type and
    -- turns plain again the moment the letters stop matching any command (same
    -- signal as the leading composer). Scans the whole line, so "run /brainstorm now"
    -- and a half-typed "/brai" both colour, while "/braix" drops back to plain.
    local from = 1
    while true do
      local s, e, tok = line:find("/([%w:_%-]+)", from)
      if not s then break end
      if slash.has_prefix(tok) then
        vim.api.nvim_buf_set_extmark(ibuf, slash_ns, lnum, s - 1, {
          end_col = e, hl_group = "ClaudeSlashMatch",
        })
      end
      from = e + 1
    end
  end

  -- Fit the height SYNCHRONOUSLY on the text change, NOT on a debounce timer. The
  -- old 16ms vim.defer_fn left a one-frame window where the buffer had already
  -- wrapped to a new screen row but the float hadn't grown yet: too short, the
  -- window scrolled the "❯" prompt line off the top and the wrapped text flashed
  -- up where the arrow had been. Fitting in the same tick as the keystroke folds
  -- the resize into that redraw, so there's no intermediate too-short frame.
  -- Nothing to coalesce: fit_height_now only triggers apply_layout on an actual
  -- row-count change (a wrap boundary crossing), not on every keystroke.
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged", "TextChangedP" }, {
    buffer   = ibuf,
    callback = function() fit_height_now(); update_slash_menu() end,
  })

  -- ↑/↓ cycle the slash menu when it's open; no-op otherwise (a single-line prompt
  -- has nothing to scroll to). <CR> is owned by the menu itself while open (see
  -- claude/slash.lua), so it isn't mapped here.
  vim.keymap.set("i", "<Up>",   function() slash.move(-1) end,
    { buffer = ibuf, nowait = true, silent = true })
  vim.keymap.set("i", "<Down>", function() slash.move(1) end,
    { buffer = ibuf, nowait = true, silent = true })

  -- Keep the bar pinned to the Claude column + bottom when the terminal/window is
  -- resized (the fixed-width panel's left edge shifts as the editor grows, so a
  -- float fixed at open-time col drifts out of the column). Shared resize helper
  -- repositions col/row/width; the callback re-fits the meters + height to the new
  -- width. close() tears the augroup down by name ("ClaudeChatFloat").
  attach_panel_float_resize(win, "ClaudeChatFloat", function(_, _, w)
    float_w = w        -- render_meters / fit_height_now wrap to this width
    apply_layout()     -- re-fit meters to the new width + resize height
  end)

  -- "❯ " prompt arrow (U+276F — not a keyboard char), highlighted terminal-green
  -- via a window-local match so it reads like a shell prompt. The arrow is
  -- display-only; the text passed to the callback excludes it.
  vim.fn.prompt_setprompt(ibuf, "❯ ")
  vim.fn.matchadd("ClaudeArrow", "^❯")

  -- Show the cursor while the chat bar is open (the panel hides it globally via
  -- guicursor). Done explicitly here rather than relying on the panel's
  -- WinLeave→restore, which was unreliable and left the cursor invisible while
  -- typing. close() re-hides it; focus returns to the read-only panel.
  vim.o.guicursor = state.real_guicursor or "a:block,a:blinkon0"

  local function close()
    -- Save unsent text BEFORE the buffer is wiped. Skip on a submit close — that
    -- text is already on its way to Claude, so the draft must clear, not persist.
    if persist_draft and not submitted and vim.api.nvim_buf_is_valid(ibuf) then
      local last = vim.api.nvim_buf_get_lines(ibuf, -2, -1, false)[1] or ""
      state.chat_draft = last
    end
    if slash.active() then slash.close() end   -- tear down the "/" menu with the bar
    vim.o.guicursor = "a:ver1-ClaudeCursorHidden"   -- re-hide; focus returns to panel
    clear_bottom_pad()   -- drop the reserved space so output reflows to the bottom
    pcall(vim.api.nvim_del_augroup_by_name, "ClaudeChatFloat")
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    -- Drop the live-bar handles so the permission card won't try to close a dead
    -- window. Guard against a stale closure clobbering a newer bar's handle.
    if state.chat_win == win then
      state.chat_win, state.chat_buf, state.chat_close = nil, nil, nil
    end
  end
  -- Publish the live handles so show_permission_card can dismiss this bar before
  -- opening the card (see state.chat_win docs).
  state.chat_win, state.chat_buf, state.chat_close = win, ibuf, close

  vim.fn.prompt_setcallback(ibuf, function(text)
    submitted = true
    if persist_draft then state.chat_draft = "" end   -- sent → drop the saved draft
    close()
    callback(text ~= "" and text or nil)
  end)

  vim.keymap.set("i", "<Esc>", function()
    -- While the "/" menu is open, Esc dismisses just the menu (stay in the bar);
    -- otherwise it closes the whole bar.
    if slash.active() then slash.close(); return end
    close(); callback(nil)
  end, { buffer = ibuf, nowait = true, silent = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = ibuf, nowait = true, silent = true })
  vim.keymap.set("n", "q",     close, { buffer = ibuf, nowait = true, silent = true })

  -- Auto-dismiss the bar whenever focus leaves it (clicking the panel/editor, or
  -- after a submit closes the window). once=true so it self-removes; close()
  -- guards an already-closed window.
  vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave" }, {
    buffer   = ibuf,
    once     = true,
    callback = function() close() end,
  })

  -- Restore any unsent text from a previous hide. Set the input line before
  -- startinsert! so the cursor lands at its end, and refit the box height in case
  -- the restored text wraps to multiple rows.
  if persist_draft and state.chat_draft ~= "" then
    vim.api.nvim_buf_set_lines(ibuf, 0, -1, false, { state.chat_draft })
    fit_height_now()
  end

  -- Draw the meters + size the box + reserve the push-up space, all up front.
  apply_layout()

  vim.cmd("startinsert!")   -- ! = start after existing content (end of prompt)
end

-- Selection-anchored input float (<leader>cq). Unlike the panel chat bar, this
-- pops right where the user is working — anchored to the cursor/selection in the
-- CURRENT file window (relative="cursor") — so they ask about highlighted code
-- in place, not on the panel. Deliberately lean: no burn meters, no panel
-- bottom-pad, no panel-column resize tracking (all of which couple the chat bar
-- to the panel). On submit the caller (ask_selection) opens/answers in the panel.
local function open_selection_float(title, callback)
  local mode_label = (state.permission_mode == "plan") and " - Plan Mode" or " - Build Mode"
  local label      = title .. mode_label

  -- Fit inside the current (file) window, clamped to a comfortable range.
  local win_w   = vim.api.nvim_win_get_width(0)
  local float_w = math.min(math.max(win_w - 8, 30), 80)

  local ibuf = vim.api.nvim_create_buf(false, true)
  vim.bo[ibuf].buftype   = "prompt"   -- <CR> fires prompt_setcallback
  vim.bo[ibuf].bufhidden = "wipe"
  vim.bo[ibuf].swapfile  = false
  vim.bo[ibuf].filetype  = "claude"   -- same modal statusline styling as the bar

  -- Anchor just below the cursor — after ask_selection escapes visual mode the
  -- cursor sits at the selection end ('>), so the box lands on the highlight.
  -- nvim auto-flips it above the line if it would run off the bottom of screen.
  local win = vim.api.nvim_open_win(ibuf, true, {
    relative  = "cursor",
    anchor    = "NW",
    row       = 1,
    col       = 0,
    width     = float_w,
    height    = 1,
    border    = "rounded",
    style     = "minimal",
    title     = " " .. label .. " ",
    title_pos = "left",
    zindex    = 60,
  })

  local border_hl = (state.permission_mode == "plan") and "ClaudeBarBorderPlan" or "ClaudeBarBorder"
  vim.wo[win].winhighlight = "FloatBorder:" .. border_hl
    .. ",FloatTitle:" .. border_hl
    .. ",NormalFloat:ClaudeBarBg"
  vim.wo[win].wrap      = true
  vim.wo[win].linebreak = true
  harden_float_scroll(win)

  -- Grow up to MAX_INPUT_ROWS as the question wraps (no meters/pad to reconcile).
  local MAX_INPUT_ROWS = 12
  local cur_rows = 1
  local function fit_height_now()
    if not vim.api.nvim_win_is_valid(win) then return end
    local rows = 0
    for _, l in ipairs(vim.api.nvim_buf_get_lines(ibuf, 0, -1, false)) do
      rows = rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(l) / float_w))
    end
    rows = math.min(math.max(rows, 1), MAX_INPUT_ROWS)
    if rows ~= cur_rows then
      cur_rows = rows
      local c = vim.api.nvim_win_get_config(win)
      c.height = rows
      vim.api.nvim_win_set_config(win, c)
    end
  end
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged", "TextChangedP" }, {
    buffer = ibuf, callback = fit_height_now,
  })

  vim.fn.prompt_setprompt(ibuf, "❯ ")
  vim.fn.matchadd("ClaudeArrow", "^❯")
  -- Ensure a visible cursor while typing (the panel hides it globally).
  vim.o.guicursor = state.real_guicursor or "a:block,a:blinkon0"

  local closed = false
  local function close()
    if closed then return end
    closed = true
    pcall(vim.api.nvim_del_augroup_by_name, "ClaudeSelectionFloat")
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  vim.fn.prompt_setcallback(ibuf, function(text)
    close()
    callback(text ~= "" and text or nil)
  end)

  vim.keymap.set("i", "<Esc>", function() close(); callback(nil) end,
    { buffer = ibuf, nowait = true, silent = true })
  vim.keymap.set("n", "<Esc>", function() close(); callback(nil) end,
    { buffer = ibuf, nowait = true, silent = true })
  vim.keymap.set("n", "q", function() close(); callback(nil) end,
    { buffer = ibuf, nowait = true, silent = true })

  -- Dismiss if focus leaves the box (clicked away). close() guards re-entry, so
  -- the submit path (which shifts focus to the panel) closing it too is harmless.
  local grp = vim.api.nvim_create_augroup("ClaudeSelectionFloat", { clear = true })
  vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave" }, {
    group = grp, buffer = ibuf, once = true,
    callback = function() close() end,
  })

  vim.cmd("startinsert!")
end
mod._open_selection_float = open_selection_float

-- Test seam: the input float is a real nvim_open_win prompt buffer, which can't
-- be driven from a headless spec (no interactive <CR>). Routing both input
-- entry points (prompt_input, ask_selection) through this indirection lets the
-- spec override it with a stub that invokes the callback synchronously. In
-- production it's just open_chat_float.
mod._open_chat_float = open_chat_float
-- Exposed for unit tests (pure markdown transform — no buffer writes).
mod._build_md_lines = build_md_lines
mod._render_table   = render_table

--- Open the chat float for the user to type a reply to Claude.
function mod.prompt_input()
  -- Block new input when a diff is pending: accepting/rejecting the edit must
  -- happen before the conversation can continue, so we don't create a race
  -- between a follow-up message and the pending file change on disk.
  if state.perm then
    vim.notify("⚠ Permission required — ←/→ select, <CR> confirm, <Esc> reject",
      vim.log.levels.WARN)
    return
  end
  if state.diff_pending then
    vim.notify("⚠ Awaiting review — accept or reject first", vim.log.levels.WARN)
    return
  end
  -- NOTE: we no longer block while Claude is working. submit() queues the message
  -- (type-ahead) and shows it shaded at the panel bottom until the current turn
  -- ends, then sends it — mirroring the Claude Code TUI.
  mod._open_chat_float("Reply to Claude", function(text)
    if not text then return end
    submit(text)
  end, { persist_draft = true })
end

-- ─── Interrupt (Goal 6.6) ─────────────────────────────────────────────────────

--- Interrupt the current turn WITHOUT killing the session.
-- Sends a stream-json control_request {subtype="interrupt"} to the live process
-- (the Claude Code control protocol). The process aborts the in-flight turn but
-- stays alive, so conversation context is preserved and the user can keep
-- chatting. Falls back to a no-op when nothing is in flight.
-- (Contrast: mod.reset() tears the whole session down and starts blank.)
function mod.interrupt()
  if not (state.job_id and state.working) then return end
  local req = vim.json.encode({
    type       = "control_request",
    request_id = uuid4(),
    request    = { subtype = "interrupt" },
  })
  pcall(vim.fn.chansend, state.job_id, req .. "\n")
  -- The process emits a result/error for the aborted turn; dispatch clears
  -- working + spinner there. Clear the spinner now too so the UI feels snappy.
  state.working = false
  stop_spinner()
  if not state.diff_pending then clear_hint() end
end

-- ─── Over-scroll clamp ────────────────────────────────────────────────────────

-- How many blank rows the panel may scroll PAST the last content line. Set to 1:
-- the view stops one line past the last content row — no dead over-scroll band
-- below the conversation. Scrolling UP to read history is unaffected (free_below
-- returns nil when the last line is off the bottom, so the clamp doesn't fire).
local SCROLL_TAIL = 1

-- Re-entrancy guard: the re-anchor below re-fires WinScrolled. The guard plus the
-- "only when over" test means the correction settles in one step (after the
-- re-anchor the last line sits at its allowed row, so the nested call is a no-op).
local clamping = false

-- Clamp panel over-scroll so the last content line can rise at most SCROLL_TAIL
-- rows above its resting position (pad_rows above the window bottom). Driven by
-- WinScrolled so it catches EVERY scroll source — mouse wheel, <C-e>/<C-d>, search
-- jumps — which a key-by-key approach can't (the wheel especially bypasses
-- normal-mode maps while the float is focused).
--
-- Measured in SCREEN rows via screenpos(), not a topline-vs-line-count formula:
-- the old formula assumed one screen row per buffer line, so wrapped prose and
-- collapsed "thinking" folds made its limit wildly wrong — it trapped the view and
-- the user couldn't scroll down to text that was really there. screenpos() reports
-- the true display row of the last line regardless of wrap/folds.
local function clamp_scroll()
  if clamping then return end
  local win = state.panel_win
  if not (win and vim.api.nvim_win_is_valid(win)) then return end
  local buf = state.panel_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  if vim.api.nvim_win_get_buf(win) ~= buf then return end

  clamping = true
  pcall(vim.api.nvim_win_call, win, function()
    -- Screen rows between the last content line and the window bottom. nil means
    -- the last line is scrolled off the BOTTOM — the user scrolled UP to read
    -- history; that's allowed, so don't clamp. (Same measurement anchor_last_line
    -- uses, hence the shared helper.)
    local gap = free_below(win, buf)
    if not gap then return end
    -- The last line legitimately rests in the band [floor, limit] above the bottom:
    -- `floor` = pad_rows (the chat bar / question card's reserved space) is the
    -- closest it may sit; `limit` adds SCROLL_TAIL of over-scroll breathing room.
    -- gap > limit → sliding off the top (re-anchor down to limit). gap < floor →
    -- the last line dropped UNDER the reserved pad — happens when a thinking fold
    -- EXPANDS above it, inserting display rows while the topline holds — so lift it
    -- back up to floor or the newest output hides behind the card. Inside the band:
    -- leave it. Both corrections pin to a target via Gzb + an <C-e> nudge (the same
    -- method as anchor_last_line); pinning to the exact boundary makes the
    -- correction only the overshoot delta, so the view holds instead of bouncing.
    local floor  = (state.pad_rows or 0)
    local limit  = floor + SCROLL_TAIL
    local target
    if gap > limit then target = limit
    elseif gap < floor then target = floor end
    if target then
      local so = vim.wo[win].scrolloff
      vim.wo[win].scrolloff = 0
      vim.cmd("keepjumps normal! Gzb")
      local fb = free_below(win, buf)
      if fb and fb < target then
        vim.cmd("keepjumps normal! " .. (target - fb) .. "\005")  -- <C-e> ×(target-fb)
      end
      vim.wo[win].scrolloff = so
    end
  end)
  clamping = false
end

-- Test seam: drive the over-scroll clamp directly in the headless spec.
mod._clamp_scroll = clamp_scroll
mod._SCROLL_TAIL  = SCROLL_TAIL

-- Mouse-wheel-down pre-empt. The WinScrolled clamp corrects AFTER a scroll lands;
-- discrete keyboard scrolls (G, <C-e>) settle in one correction, but the mouse wheel
-- streams events continuously, so the clamp fights every tick → the bounce the user
-- only saw with the mouse. Here we scroll only the room left below the limit and
-- SWALLOW once at it, so the over-scroll never happens and there's nothing to undo.
-- Scroll-up (<ScrollWheelUp>) stays native so reading history is unrestricted.
local WHEEL_STEP = 3   -- rows per wheel notch (matches the default 'mousescroll' ver)
local function panel_wheel_down()
  local win = state.panel_win
  if not (win and vim.api.nvim_win_is_valid(win)) then return end
  local buf = state.panel_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  if vim.api.nvim_win_get_buf(win) ~= buf then return end
  pcall(vim.api.nvim_win_call, win, function()
    local step  = WHEEL_STEP
    local gap   = free_below(win, buf)
    -- gap nil = last line is below the viewport (scrolled up in history): tons of
    -- room, scroll the full notch. Otherwise cap the step to the rows left so we
    -- land exactly on the limit and never overshoot (overshoot is what bounced).
    if gap then
      local room = ((state.pad_rows or 0) + SCROLL_TAIL) - gap
      if room <= 0 then return end          -- already at the limit → swallow the notch
      if room < step then step = room end
    end
    local so = vim.wo[win].scrolloff
    vim.wo[win].scrolloff = 0
    vim.cmd("keepjumps normal! " .. step .. "\005")  -- step × <C-e>
    vim.wo[win].scrolloff = so
  end)
end

-- ─── Panel window placement ───────────────────────────────────────────────────

-- Open a new vertical split, place it at the far-right column (via
-- term_layout.place_vertical), and associate it with the panel buffer.
-- Also hooks up claude_diff autocmds (on_panel_open) and the input keymaps.
local function open_panel_window(buf)
  local width = panel_width()
  -- vsplit creates a new window; the new window becomes current.
  -- We immediately retarget it to the panel buffer before resizing.
  vim.cmd("vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)

  -- place_vertical calls `wincmd L` to push the panel to the far-right column,
  -- then resizes it to `width` columns. Same strategy as the OpenCode panel;
  -- see term_layout.lua header for why this defeats toggleterm's split grouping.
  require("utils.term_layout").place_vertical(width)

  state.panel_win    = win
  state.claude_active = true
  -- foldmethod must be window-local (vim.wo), not buffer-local (vim.bo).
  -- Set it here, after the window is created and associated with the buffer,
  -- so render_thinking's nvim_win_call fold commands work correctly.
  vim.wo[win].foldmethod = "manual"
  -- Custom foldtext so a collapsed thinking block reads as "▶ Thought · <time>"
  -- (see mod._foldtext) instead of Vim's default "+-- N lines:" line.
  vim.wo[win].foldtext = "v:lua.require('utils.claude')._foldtext()"

  -- Pin the panel width so growing the OS/terminal window adds columns to the
  -- editor (the non-fixed window), not the panel. Without this the rightmost
  -- window absorbs the extra width and the Claude panel balloons on resize.
  vim.wo[win].winfixwidth = true

  -- Panel background = ClaudeNormal (CursorLine-derived gray) so the whole Claude
  -- column reads as one flush surface with the chat bar.
  vim.wo[win].winhighlight = PANEL_HL_BASE

  -- Hide end-of-buffer "~" filler lines. The panel is an output surface; the
  -- tildes below the content add visual noise and imply empty-file semantics.
  -- eob: blank the ~ end-of-buffer markers; fold: blank the trailing fill dashes
  -- after the foldtext so a collapsed "▶ Thought" row reads clean to the edge.
  vim.wo[win].fillchars = "eob: ,fold: "

  -- Disable cursorline in the panel. It's a read-only output surface, and the
  -- global cursorline=true otherwise paints a gray strip across whatever row the
  -- cursor rests on (e.g. the banner separator) — that strip is the "orange line
  -- background not flush" artifact. Off here, every row shares the panel bg.
  vim.wo[win].cursorline = false

  -- Panel is a read-only output surface — line numbers add noise and imply an
  -- editable file. Disable both absolute and relative numbers in this window.
  vim.wo[win].number         = false
  vim.wo[win].relativenumber = false
  -- No gutters: panel_width() uses nvim_win_get_width as the text width, so any
  -- reserved fold/sign column would make padded surfaces (code blocks, cards)
  -- overshoot by the gutter width and soft-wrap. Thinking folds are toggled via
  -- the clickable foldtext row + `za`, not the foldcolumn markers, so 0 is safe.
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].signcolumn = "no"

  -- smoothscroll: scroll by SCREEN rows, so the chat-bar push-up (anchor_last_line)
  -- and clamp can lift a partially-wrapped line precisely instead of snapping to
  -- whole-line boundaries. scrolloff=0: nothing holds the last line off the bottom,
  -- so `zb` can place it flush (the bar reserves space via the pad, not scrolloff).
  vim.wo[win].smoothscroll = true
  vim.wo[win].scrolloff    = 0

  -- Enable FileChangedShell interceptor + disable autoread for the session.
  require("utils.claude_diff").on_panel_open()

  local grp = vim.api.nvim_create_augroup("ClaudeDirTrack", { clear = true })

  -- Keep the banner path (and claude's run cwd) tracking the directory the user
  -- is in. DirChanged fires on every :cd / :lcd / autochdir move; we update
  -- stored_root so the next send runs there, and rewrite the banner path line.
  vim.api.nvim_create_autocmd("DirChanged", {
    group = grp,
    callback = function()
      if not state.claude_active then return end
      state.stored_root = vim.fn.getcwd()
      update_banner_cwd(vim.fn.fnamemodify(state.stored_root, ":~"))
    end,
  })

  -- Re-fit the separator lines to the panel width whenever the window resizes
  -- (OS window drag, :resize, terminal size change) so the dividers never wrap.
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = grp,
    callback = function()
      if not state.claude_active then return end
      refit_separators()
    end,
  })

  -- Cap over-scroll so the conversation can't be flung off the top of the window.
  -- The mouse wheel is pre-empted below (prevents the over-scroll outright); this
  -- WinScrolled clamp is the backstop for everything else — G, search jumps, page
  -- keys — that the wheel map can't intercept. See clamp_scroll for the math.
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = grp,
    callback = function()
      if not state.claude_active then return end
      clamp_scroll()
    end,
  })

  -- Mouse-wheel-down pre-empt (see panel_wheel_down): scroll only the room left to
  -- the limit so the continuous wheel stream can't out-run the after-the-fact clamp
  -- and bounce. Buffer-local so it only governs the panel; wheel-up stays native.
  if state.panel_buf and vim.api.nvim_buf_is_valid(state.panel_buf) then
    vim.keymap.set("n", "<ScrollWheelDown>", panel_wheel_down,
      { buffer = state.panel_buf, silent = true })
  end

  -- Hide the cursor while the panel is focused. guicursor is global so we save on
  -- WinEnter and restore on WinLeave. winhighlight cannot override Cursor/CursorNC —
  -- guicursor is the only per-focus API. We also stash the real (visible) guicursor
  -- in module state so the chat bar can explicitly restore it on open rather than
  -- depending on the WinLeave→restore race, which left the cursor invisible while
  -- typing if _saved_gc had already been consumed.
  local function remember_real_gc()
    if vim.o.guicursor ~= "a:ver1-ClaudeCursorHidden" then
      state.real_guicursor = vim.o.guicursor
    end
  end
  local _saved_gc = nil
  vim.api.nvim_create_autocmd("WinEnter", {
    group  = grp,
    buffer = buf,
    callback = function()
      if vim.o.guicursor ~= "a:ver1-ClaudeCursorHidden" then
        _saved_gc = vim.o.guicursor
      end
      remember_real_gc()
      vim.o.guicursor = "a:ver1-ClaudeCursorHidden"
    end,
  })
  vim.api.nvim_create_autocmd("WinLeave", {
    group  = grp,
    buffer = buf,
    callback = function()
      if _saved_gc then
        vim.o.guicursor = _saved_gc
        _saved_gc = nil
      end
    end,
  })
  -- vsplit creates the window before nvim_win_set_buf, so WinEnter fires with
  -- the wrong buffer and the buffer= filter skips it. Hide directly.
  _saved_gc = vim.o.guicursor
  remember_real_gc()
  vim.o.guicursor = "a:ver1-ClaudeCursorHidden"


  -- Buffer-local keymaps: must be set after the buffer is associated with a
  -- window (some keymaps reference the window for focus checks).
  set_panel_keymaps(buf)
  clear_hint()
  return win
end

-- ─── Toggle / open / reset (Goals 6.8, 6.6) ──────────────────────────────────

--- Toggle the panel open or closed (`<leader>cc`).
-- @param root_override string|nil  When given (dock-launch flow), this is the
--   authoritative project root the panel anchors to — claude runs in it and the
--   banner shows it. Without it (<leader>cc) the root is detected from the
--   current buffer/cwd. The override exists because the dock picker knows the
--   chosen project, while cwd may still be the launcher dir (~/dev) at this point.
function mod.toggle(root_override)
  if not ensure_available() then return end

  -- Snapshot the window the user is in BEFORE anything steals focus (the mutex
  -- toggle below, or open_panel_window). This is the editor window whose file we
  -- attach as ambient context (FINDINGS § Q-CTX).
  local prev_win = vim.api.nvim_get_current_win()

  -- Mutex: if OpenCode is open, close it before opening Claude (FINDINGS.md § A5).
  -- Both panels use place_vertical(wincmd L); running both simultaneously would
  -- strand one of them on a stale alternate screen. One panel at a time.
  local ok, opencode = pcall(require, "utils.opencode")
  if ok and opencode.state and opencode.state.opencode_active then
    opencode.toggle()
    vim.notify(
      "Claude panel open — OpenCode closed (<leader>oc to switch)",
      vim.log.levels.INFO
    )
  end

  -- If the panel window is currently visible, close it. The persistent process
  -- is torn down too — a hidden panel shouldn't keep a claude session running.
  if state.claude_active and state.panel_win
      and vim.api.nvim_win_is_valid(state.panel_win) then
    stop_process()
    widgets.close_todo_widget()
    vim.api.nvim_win_close(state.panel_win, true)
    state.panel_win    = nil
    state.claude_active = false
    state.host_file     = nil
    state.host_ctx_last_path = nil
    pcall(vim.api.nvim_del_augroup_by_name, "ClaudeDirTrack")
    require("utils.claude_diff").on_panel_close()
    return
  end

  -- Opening: the panel anchors to whatever directory the user is in — the
  -- current working directory (vim.fn.getcwd()) — so claude runs there and the
  -- banner path matches the editor cwd shown in the title bar. A dock launch may
  -- pass an explicit root before cwd has settled, so it takes precedence. The
  -- DirChanged autocmd (see open_panel_window) keeps this live as the user moves.
  local root        = root_override or vim.fn.getcwd()
  state.stored_root = root

  local buf = ensure_panel_buf()
  -- Capture the open file + arm a fresh session's ambient context BEFORE the
  -- panel window steals focus (FINDINGS § Q-CTX). fresh = brand-new buffer, not
  -- a reopen (which reuses scrollback + an already-primed session).
  local fresh         = vim.api.nvim_buf_line_count(buf) <= 1
  state.host_file     = current_host_file(prev_win)
  if fresh then state.host_ctx_last_path = nil end
  open_panel_window(buf)

  -- Render banner on fresh buffer only (reopen after close reuses scrollback).
  -- The persistent subprocess is NOT spawned here; the first send() spawns it.
  if fresh then
    -- cwd + version known now (version from the binary path); model shows the
    -- picked --model if set, else fills from system/init after the first message.
    -- Show ~-relative path so long absolute roots don't overflow the panel.
    render_banner(state.model or "", binary_version(),
      vim.fn.fnamemodify(state.stored_root or root, ":~"))
  end
  clear_hint()
  -- No auto-prompt: matching OpenCode, the open file is injected on the user's
  -- first real message (attach_host_context) — and re-injected on a file switch —
  -- not announced up front. v2 surfaces each attach as a dim echo note, not a
  -- separate prompt.
end

--- Open the panel without toggling — dock-launch flow (FINDINGS.md § A2).
-- Idempotent: if the panel is already visible, does nothing.
-- @param root string|nil  Authoritative project root (passed by the dock picker).
function mod.open(root)
  if state.claude_active and state.panel_win
      and vim.api.nvim_win_is_valid(state.panel_win) then
    return
  end
  mod.toggle(root)
end

--- Hard reset: kill the current session and start a completely blank one.
-- Unlike <Esc> (interrupt that keeps the session + history), this kills the
-- process and clears the panel buffer so the next send spawns a brand-new
-- session with an empty scrollback. Model + permission-mode choices persist.
function mod.reset()
  -- Capture the live panel window BEFORE state is cleared. reset() re-opens via
  -- toggle()→open_panel_window, which always `vsplit`s a NEW window. Deleting the
  -- old panel buffer below does NOT close its window when the panel is the only
  -- window (Neovim keeps one window alive, showing a blank buffer), so without
  -- closing it the vsplit leaves a stray blank pane beside the fresh panel
  -- (live-reproduced 2026-07-03). Closed after toggle(), once a 2nd window exists.
  local old_win = state.panel_win

  -- Kill the persistent process if running. on_exit fires asynchronously but
  -- stop_process nulls job_id now so it becomes a no-op when it arrives.
  stop_process()

  -- Clear all state synchronously so toggle() below starts with a clean slate.
  -- session_id is cleared too so the next send starts a fresh session rather
  -- than carrying anything over from the one we just abandoned.
  state.job_id        = nil
  state.session_id    = nil
  state.session_cost  = nil
  state.stored_root   = nil
  state.diff_queue    = {}
  state.queue         = {}
  state.working       = false
  state.system_ready  = false
  state.diff_pending  = false
  state.prewrite      = nil
  state.host_file     = nil
  state.host_ctx_last_path = nil
  state.tool_results  = {}
  state.tool_meta     = {}
  state.search_blocks = {}
  state.todos         = nil
  state.todo_seq      = nil
  widgets.close_todo_widget()
  -- Drop captured subagent sessions on session reset + close the switcher bar and
  -- any open drill-in view.
  state.subagents     = nil
  state.subagent_sel  = 1
  widgets.close_subagent_view()
  widgets.close_subagent_bar()
  if state.perm and state.perm.win and vim.api.nvim_win_is_valid(state.perm.win) then
    pcall(vim.api.nvim_win_close, state.perm.win, true)
  end
  state.perm          = nil
  if state.diff_card and state.diff_card.win and vim.api.nvim_win_is_valid(state.diff_card.win) then
    pcall(vim.api.nvim_win_close, state.diff_card.win, true)
  end
  state.diff_card      = nil
  state.claude_active = false
  process.clear_stdout()

  -- Delete the old panel buffer so ensure_panel_buf() creates a fresh one.
  -- Without this, the new session would append to the old scrollback.
  if state.panel_buf and vim.api.nvim_buf_is_valid(state.panel_buf) then
    vim.api.nvim_buf_delete(state.panel_buf, { force = true })
  end
  state.panel_buf = nil
  state.panel_win = nil

  require("utils.claude_diff").on_panel_close()
  mod.toggle()

  -- Close the stale pre-reset panel window if it survived (it does when the panel
  -- was the only window — see old_win comment above). toggle() has now opened the
  -- fresh panel, so a second window exists and closing the old one is safe.
  if old_win and old_win ~= state.panel_win
      and vim.api.nvim_win_is_valid(old_win)
      and #vim.api.nvim_tabpage_list_wins(0) > 1 then
    pcall(vim.api.nvim_win_close, old_win, true)
  end
end

-- ─── Model picker + plan-mode toggle ─────────────────────────────────────────

-- Selectable models, newest-first per family. No selection (state.model stays
-- nil) leaves --model unset, so the CLI/account default is used. Bare aliases
-- ("opus"/"sonnet"/"haiku") resolve to the latest of each family at spawn
-- time, matching the terminal's `--model opus|sonnet|haiku`; older/pinned
-- versions use the dated full id since the CLI has no bare alias for them.
local MODEL_CHOICES = {
  { label = "Fable 5",    value = "claude-fable-5" },
  { label = "Opus 4.8",   value = "opus" },
  { label = "Opus 4.7",   value = "claude-opus-4-7" },
  { label = "Opus 4.6",   value = "claude-opus-4-6" },
  { label = "Sonnet 5",   value = "sonnet" },
  { label = "Sonnet 4.6", value = "claude-sonnet-4-6" },
  { label = "Haiku 4.5",  value = "haiku" },
}

--- Pick the model for the panel session (`<leader>cm`).
-- Model is a spawn-time flag, so a running session can't switch mid-flight: we
-- stop the current process and let the next send respawn with the new --model.
-- That resets conversation context, so we tell the user. The banner updates at
-- once to reflect the choice.
function mod.pick_model()
  vim.ui.select(MODEL_CHOICES, {
    prompt = "Claude model",
    kind = "claude_model",   -- lets dressing.lua size this picker independently
    format_item = function(item) return item.label end,
  }, function(choice)
    if not choice then return end
    state.model = choice.value
    -- Tear down the live process so the next message respawns with --model.
    local had_session = state.job_id ~= nil
    stop_process()
    -- Reflect immediately in the banner. friendly_model maps the alias/id to
    -- the full display name ("sonnet" → "Sonnet 5").
    local fm = state.model and friendly_model(state.model) or ""
    state.model_display = fm   -- modal statusline; "" until system/init re-fills it
    update_banner_model(fm)
    vim.notify(
      "Claude model → " .. choice.label ..
      (had_session and "  (new session — context reset)" or ""),
      vim.log.levels.INFO
    )
  end)
end

-- Valid reasoning-effort levels (must match the CLI's --effort choices).
local EFFORT_LEVELS = { low = true, medium = true, high = true, xhigh = true, max = true }

-- Apply an effort level: store it and tear down the live process so the next
-- message respawns with --effort. Like a model change, this resets conversation
-- context, so we say so. Shared by the slider's confirm and the "/effort <level>"
-- shorthand.
local function apply_effort(level)
  state.effort = level
  local had_session = state.job_id ~= nil
  stop_process()
  vim.notify(
    "Claude effort → " .. level ..
    (had_session and "  (new session — context reset)" or ""),
    vim.log.levels.INFO
  )
end

--- Set the reasoning-effort level for the panel session (`/effort`).
-- With a valid `level` arg ("/effort high") it applies immediately; otherwise it
-- opens the slider preselected at the current level. Effort is a spawn-time flag,
-- so applying respawns the process (see apply_effort).
function mod.pick_effort(level)
  if level and EFFORT_LEVELS[level] then
    apply_effort(level)
    return
  end
  effort.open(state.effort or "medium", apply_effort)
end

--- The current effort level for the modal statusline (defaults to "medium" when
--- unset, matching the CLI's shown default). Shown right of the model.
function mod.current_effort()
  return effort.current()
end

-- Accepted advisor aliases for the "/advisor <model>" shorthand.
local ADVISOR_MODELS = { opus = true, sonnet = true, fable = true }

-- Apply an advisor model (nil = No advisor / unset). Unlike --model and --effort
-- this does NOT respawn: an apply_flag_settings control_request changes the setting
-- on the LIVE process, so conversation context is preserved (matches the TUI). When
-- no session is running yet, we only store it — the next spawn seeds --advisor from
-- state.advisor_model (see process.build_args). Shared by the picker's confirm and
-- the "/advisor <model>" shorthand.
local function apply_advisor(id)
  state.advisor_model = id
  if state.job_id then
    local req = vim.json.encode({
      type       = "control_request",
      request_id = uuid4(),
      request    = {
        subtype  = "apply_flag_settings",
        -- vim.NIL encodes to JSON null, which unsets advisorModel ("No advisor").
        settings = { advisorModel = id or vim.NIL },
      },
    })
    pcall(vim.fn.chansend, state.job_id, req .. "\n")
  end
  vim.notify("Claude advisor → " .. advisor.current_label(), vim.log.levels.INFO)
end

--- Choose the advisor model for the panel session (`/advisor`). With a valid alias
--- ("/advisor opus") it applies immediately; "off"/"none" disables it; a bare
--- "/advisor" opens the picker preselected at the current advisor. Applied live
--- (no respawn) via apply_advisor.
function mod.pick_advisor(id)
  if id and ADVISOR_MODELS[id] then apply_advisor(id); return end
  if id == "off" or id == "none" then apply_advisor(nil); return end
  advisor.open(apply_advisor)
end

--- The current advisor label for the modal statusline ("Opus 4.8" / "off").
function mod.current_advisor()
  return advisor.current_label()
end

--- Friendly display name of the panel's current model (e.g. "Sonnet 4.6") for the
--- modal statusline. Prefers the picked model, falls back to whatever system/init
--- last reported, then to a generic "Claude" so the segment is never blank.
function mod.current_model()
  if state.model_display and state.model_display ~= "" then return state.model_display end
  local fm = state.model and friendly_model(state.model) or ""
  if fm ~= "" then return fm end
  -- Before the panel's first turn, borrow the model from the burn state file as a
  -- hint (last interactive session's model); fall back to a generic label.
  local bm = require("utils.claude_burn").model()
  if bm ~= "" then return bm end
  return "Claude"
end

--- Session cost of the panel's OWN subprocess, formatted "$0.42", for the
--- statusline. "$0.00" before the first turn completes; tracks the fresh session
--- spawned in this Neovim, not the shared burn-state file's last writer.
function mod.session_cost()
  return string.format("$%.2f", state.session_cost or 0)
end

-- Whitelist of caveman intensity/independent modes that count as "enabled". Mirrors
-- the case statement in the caveman plugin's caveman-statusline.sh so we render a
-- badge for exactly the same set the plugin considers active. "off" is absent: the
-- activate hook DELETES the flag file in off mode, so absence already means off.
local CAVEMAN_MODES = {
  lite = true, full = true, ultra = true,
  ["wenyan-lite"] = true, wenyan = true,
  ["wenyan-full"] = true, ["wenyan-ultra"] = true,
  commit = true, review = true, compress = true,
}

--- True when the user's caveman plugin is currently enabled, for the statusline
--- "CAVEMAN" badge. Reads the plugin's flag file (~/.claude/.caveman-active, or
--- $CLAUDE_CONFIG_DIR/.caveman-active) the same hardened way the plugin's own
--- statusline does: a missing file means off (the activate hook unlinks it then),
--- symlinks are refused (a local attacker could point it at a secret), and the
--- content is capped + validated against the mode whitelist before we trust it.
function mod.caveman_active()
  local dir  = vim.env.CLAUDE_CONFIG_DIR
  if not dir or dir == "" then dir = vim.fn.expand("~/.claude") end
  local flag = dir .. "/.caveman-active"
  -- lstat (NOT stat) so a symlink is seen as a symlink, not followed; reject it.
  local st = vim.loop.fs_lstat(flag)
  if not st or st.type ~= "file" then return false end
  local fd = vim.loop.fs_open(flag, "r", 438)
  if not fd then return false end
  local data = vim.loop.fs_read(fd, 64, 0) or ""
  vim.loop.fs_close(fd)
  local mode = data:gsub("[\r\n]", ""):lower():match("^%s*(.-)%s*$")
  return CAVEMAN_MODES[mode] == true
end

--- Toggle Plan mode for the panel session (`<leader>cp`).
-- Plan mode is the --permission-mode plan flag (read-only planning; no edits).
-- Like the model, it's spawn-time, so toggling respawns; context resets.
function mod.toggle_plan()
  state.permission_mode = (state.permission_mode == "plan") and "default" or "plan"
  local on = state.permission_mode == "plan"
  local had_session = state.job_id ~= nil
  stop_process()
  vim.notify(
    "Claude Plan mode " .. (on and "ON" or "OFF") ..
    (had_session and "  (new session — context reset)" or ""),
    vim.log.levels.INFO
  )
end

-- ─── Ask-selection (`<leader>cq`, Goal 6.7) ───────────────────────────────────

-- Read the last visual selection from '< and '> marks.
-- Must be called after leaving visual mode — the marks are only flushed to the
-- current selection when visual mode is exited. Matches the implementation in
-- opencode.lua get_visual_selection (same edge cases apply).
local function get_visual_selection()
  local s = vim.fn.getpos("'<")
  local e = vim.fn.getpos("'>")
  local lines = vim.api.nvim_buf_get_lines(0, s[2] - 1, e[2], false)
  if #lines == 0 then return "" end
  local end_col = e[3]
  -- selection=exclusive: '> points one past the last char; subtract 1 to match
  -- the actual last character byte (mirrors the opencode.lua correction).
  if vim.o.selection == "exclusive" then
    end_col = end_col - 1
  end
  lines[#lines] = lines[#lines]:sub(1, end_col)
  lines[1]      = lines[1]:sub(s[3])
  return table.concat(lines, "\n")
end

--- Ask Claude about a visual selection (`<leader>cq`).
-- Opens the panel if needed, then sends "question\n\n```\nselection\n```"
-- as a JSON user message. The fenced code block tells Claude the selection
-- is code, not prose.
function mod.ask_selection()
  if not ensure_available() then return end

  -- This is a mode="v" keymap: it fires while still in visual mode.
  -- Escape to normal mode first so '< and '> flush to the CURRENT selection.
  -- Without this, the marks hold the PREVIOUS selection (empty on first use).
  if vim.fn.mode():match("[vV\22]") then
    vim.cmd("normal! \27")
  end

  local selection = get_visual_selection()
  if selection == "" then
    vim.notify("Claude: no text selected", vim.log.levels.WARN)
    return
  end
  -- Filetype of the source file → the fenced-block language, so the selection
  -- renders syntax-highlighted (both in the panel echo and for Claude). Captured
  -- now while the file buffer is still current — the float switches buffers.
  local lang = vim.bo.filetype or ""

  -- Input pops at the selection in the FILE window (not on the panel), so the
  -- user asks about the highlight in place. On submit the panel opens (if closed)
  -- or answers in the already-open panel.
  mod._open_selection_float("Ask Claude about selection", function(question)
    if not question then return end
    -- Open the panel first (idempotent if already open), then send.
    mod.open()
    -- vim.schedule: mod.open() may have triggered autocmds and UI redraws;
    -- sending the message after a scheduler tick ensures the panel is fully
    -- initialised before we try to write to the subprocess stdin.
    vim.schedule(function()
      submit(question .. "\n\n```" .. lang .. "\n" .. selection .. "\n```")
    end)
  end)
end

-- ─── Diff state bridge (called by claude_diff.lua) ────────────────────────────

--- Called by claude_diff when a vimdiff opens — locks the input bar and raises
-- the Accept/Reject card (Goal 14.3). `info` is { path, kind } — kind is "new"
-- (Claude-created file) or "edit" (existing file changed); nil path skips the
-- card (defensive — on_diff_open should always be called with one in practice).
-- The user must accept or reject the proposed edit before sending another
-- message; allowing a follow-up while the file is in-diff risks confusing
-- Claude with a half-applied change still on disk.
function mod.on_diff_open(info)
  state.diff_pending = true
  set_hint("⚠ Awaiting review — <leader>ca accept  <leader>cx reject", "ClaudeLabel")
  local path = info and info.path
  if path then
    -- pcall so a card-rendering failure can't leave diff_pending set without
    -- ANY visible way to resolve it — the hint above (and the winbar fallback
    -- in claude_diff.lua) still tell the user how to proceed via <leader>ca/cx.
    local ok, err = pcall(show_diff_card, path, info.kind)
    if not ok then
      vim.notify("Claude: diff review card failed to render (" .. tostring(err) .. ")",
        vim.log.levels.ERROR)
    end
  end
end

--- Called by claude_diff when the current diff is resolved — unlocks input.
function mod.on_diff_close()
  state.diff_pending = false
  -- The card may still be up if the diff resolved via the winbar/<leader>ca/cx
  -- fallback rather than the card itself — drop it either way.
  close_diff_card()
  if not state.working then
    clear_hint()
    -- Review done: release any messages queued during the diff.
    mod._maybe_send_next()
  end
  if state.diff_card_reopen_bar then
    state.diff_card_reopen_bar = false
    vim.schedule(function() mod.prompt_input() end)
  end
end

return mod
