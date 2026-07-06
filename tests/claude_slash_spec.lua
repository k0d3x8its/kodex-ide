-- tests/claude_slash_spec.lua
-- Slash-command menu (claude/slash.lua): the "/" picker above the chat bar.
-- Proves: (1) system/init captures slash_commands into state; (2) prefix filter +
-- valid-prefix detection (drives the input-span colour); (3) description resolution
-- from on-disk skill files; (4) the menu float open→move→select→close lifecycle.
-- Run: nvim --headless -u NONE --cmd "set runtimepath+=." -c "luafile tests/claude_slash_spec.lua"

-- Isolate the slash-command disk cache to a temp file BEFORE requiring the module
-- (CACHE_PATH is read at load time) so the fake test list never clobbers the real
-- ~/.local/state cache.
vim.env.KODEX_CLAUDE_SLASH_CACHE = vim.fn.tempname() .. "_slash_cache.json"

local H = dofile("tests/helpers.lua")
H.stub_project_root("/tmp")

-- Subprocess + module stubs (mirror claude_stream_spec.lua).
local captured_stdout_cb = nil
vim.fn.jobstart = function(_, opts) captured_stdout_cb = opts.on_stdout; return 99 end
vim.fn.jobstop  = function() end
vim.fn.chansend = function(_, data) return #data end
vim.fn.chanclose = function() end
package.loaded["utils.term_layout"] = { place_vertical = function() end }
package.loaded["utils.claude_diff"] = {
  on_panel_open = function() end, on_panel_close = function() end,
  on_diff_open = function() end, on_diff_close = function() end,
  watch = function() end, poll = function() end,
}
package.loaded["utils.opencode"] = { state = { opencode_active = false }, toggle = function() end }

local claude = require("utils.claude")
claude.setup({ width_pct = 0.40 })
claude.is_available = function() return true end
local slash = require("utils.claude.slash")   -- wired by init's slash.wire{}

local function feed(ev)
  captured_stdout_cb(99, { vim.json.encode(ev), "" }, "stdout")
  vim.wait(30)
end

vim.cmd("cd /tmp")
claude.toggle()
vim.wait(30)
claude._send("hello")   -- spawns the process, captures on_stdout
vim.wait(30)

-- ── S1: system/init captures slash_commands ──────────────────────────────────
feed({ type = "system", subtype = "init", model = "claude-opus-4-8",
  claude_code_version = "2.1.201",
  slash_commands = { "brainstorm", "diagnose", "review", "compact", "changelog" } })

H.check("S1 slash_commands captured into state",
  type(claude.state.slash_commands) == "table" and #claude.state.slash_commands == 5)

-- A later empty init must NOT wipe the captured list (fires once per turn).
feed({ type = "system", subtype = "init", model = "claude-opus-4-8", slash_commands = {} })
H.check("S1 later empty init does not clobber the list",
  claude.state.slash_commands ~= nil and #claude.state.slash_commands == 5)

-- ── S1b: init capture persisted the list to the disk cache; ensure_commands
-- reloads it into a fresh (nil) session so the "/" menu works pre-first-message.
claude.state.slash_commands = nil          -- simulate a fresh panel (no init yet)
slash.ensure_commands()
H.check("S1b disk cache reseeds slash_commands before any message",
  claude.state.slash_commands ~= nil and #claude.state.slash_commands == 5)

-- ── S2: prefix detection (drives input-span colour) ───────────────────────────
H.check("S2 empty query is a valid prefix", slash.has_prefix("") == true)
H.check("S2 'br' matches brainstorm",        slash.has_prefix("br") == true)
H.check("S2 'diag' matches diagnose",        slash.has_prefix("diag") == true)
H.check("S2 'zzz' matches nothing",          slash.has_prefix("zzz") == false)
H.check("S2 'brainx' (past the match) fails", slash.has_prefix("brainx") == false)

-- ── S3: description resolution from on-disk skill files ───────────────────────
-- diagnose + brainstorm are real ~/.claude/skills with description frontmatter.
local d = slash._resolve_desc("diagnose")
H.check("S3 diagnose resolves a non-empty description",
  type(d) == "string" and #d > 0, tostring(d))
H.check("S3 a bogus command resolves to nil",
  slash._resolve_desc("definitely-not-a-command-xyz") == nil)

-- ── S4: menu float lifecycle (open → move → select → close) ───────────────────
local ibuf = vim.api.nvim_create_buf(false, true)
H.check("S4 menu starts closed", slash.active() == false)

slash.open(ibuf, "", 3, function() end)   -- empty query → all commands, sorted
H.check("S4 menu opens", slash.active() == true)
-- Sorted list includes the LOCAL_COMMANDS (advisor, effort): advisor, brainstorm,
-- changelog, compact, diagnose, effort, review → first is advisor (leading "a").
H.check("S4 first selection is the alphabetical first (advisor)",
  slash.selected() == "advisor", tostring(slash.selected()))

slash.move(1)
H.check("S4 ↓ advances the selection", slash.selected() == "brainstorm", tostring(slash.selected()))
slash.move(-1)
H.check("S4 ↑ returns to the top", slash.selected() == "advisor", tostring(slash.selected()))
slash.move(-1)   -- clamp at top
H.check("S4 ↑ clamps at the first row", slash.selected() == "advisor")

-- Re-filter to a prefix: only "c*" commands, selection resets to the top.
slash.open(ibuf, "c", 3, function() end)
H.check("S4 prefix 'c' narrows to changelog/compact",
  slash.selected() == "changelog", tostring(slash.selected()))

slash.close()
H.check("S4 menu closes", slash.active() == false)

-- Empty-query then a no-match query: menu still opens but has no rows.
slash.open(ibuf, "zzz", 3, function() end)
H.check("S4 no-match query opens an empty menu (no crash)",
  slash.active() == true and slash.selected() == nil)
slash.close()

-- ── S5: prompt-prefixed integration (the real chat-bar path) ──────────────────
-- REGRESSION: a prompt buffer keeps the "❯ " prompt AS part of the buffer line, so
-- the real typed line is "❯ /cmd", not "/cmd". update_slash_menu must strip the
-- prompt before matching, else the menu never opens live (the shipped-then-fixed
-- bug). Drive the REAL chat float: set a prompt-prefixed line + fire TextChangedI.
claude._open_chat_float("Reply to Claude", function() end)
vim.wait(30)
local cbuf   = claude.state.chat_buf
local prompt = vim.fn.prompt_getprompt(cbuf)
local islash_ns = vim.api.nvim_get_namespaces()["claude_slash_input"]
local function type_prompt_line(s)
  vim.api.nvim_buf_set_lines(cbuf, -2, -1, false, { prompt .. s })
  vim.api.nvim_exec_autocmds("TextChangedI", { buffer = cbuf })
  vim.wait(30)
end
local function span_hl()
  local m = vim.api.nvim_buf_get_extmarks(cbuf, islash_ns, 0, -1, { details = true })
  return m[1] and m[1][3], m[1] and m[1][4].hl_group   -- start col, hl
end

type_prompt_line("/br")
H.check("S5 menu opens on a prompt-prefixed '/br' (prompt stripped)",
  slash.active() == true, tostring(slash.selected()))
local col, hl = span_hl()
H.check("S5 colour span starts after the prompt (col == prompt bytelen)", col == #prompt, tostring(col))
H.check("S5 valid prefix colours ClaudeSlashMatch", hl == "ClaudeSlashMatch", tostring(hl))

type_prompt_line("/zzznope")
local _, hl2 = span_hl()
H.check("S5 no-match leaves the span PLAIN (no highlight, not red)", hl2 == nil, tostring(hl2))

type_prompt_line("/brainstorm ")   -- trailing space => command chosen, menu closes
H.check("S5 a space after the command closes the menu", slash.active() == false)

-- ── S6: is_command exact match (full name + post-":" suffix) ───────────────────
claude.state.slash_commands = { "brainstorm", "compound-engineering:ce-code-review" }
H.check("S6 exact full name is a command",    slash.is_command("brainstorm") == true)
H.check("S6 namespaced suffix is a command",  slash.is_command("ce-code-review") == true)
H.check("S6 full namespaced name is a command", slash.is_command("compound-engineering:ce-code-review") == true)
H.check("S6 a partial prefix is NOT an exact command", slash.is_command("brain") == false)
H.check("S6 an unknown token is not a command", slash.is_command("nope-xyz") == false)

-- ── S7: highlight a valid "/command" ANYWHERE in the line (not just col 0) ─────
-- A command mid-sentence (after other text) must colour ClaudeSlashMatch over the
-- "/token" span; the picker menu stays closed (it's not a bare leading "/query").
type_prompt_line("please run /brainstorm now")
H.check("S7 mid-line command leaves the picker closed", slash.active() == false)
do
  local marks = vim.api.nvim_buf_get_extmarks(cbuf, islash_ns, 0, -1, { details = true })
  local found = false
  local line  = vim.api.nvim_buf_get_lines(cbuf, -2, -1, false)[1]
  local at    = line:find("/brainstorm", 1, true) - 1   -- 0-based byte col of "/"
  for _, m in ipairs(marks) do
    if m[3] == at and m[4].hl_group == "ClaudeSlashMatch" then found = true end
  end
  H.check("S7 the mid-line '/brainstorm' span is highlighted", found, tostring(#marks))
end

-- A mid-line "/notacommand" must NOT be highlighted.
type_prompt_line("run /notacommand now")
do
  local marks = vim.api.nvim_buf_get_extmarks(cbuf, islash_ns, 0, -1, { details = true })
  H.check("S7 a bogus mid-line command is not highlighted", #marks == 0, tostring(#marks))
end

-- Mid-line highlight tracks a live PREFIX: a half-typed "/brai" stays lit (prefix
-- of brainstorm); one more wrong letter "/braix" drops back to plain.
local function has_midline_mark()
  return #vim.api.nvim_buf_get_extmarks(cbuf, islash_ns, 0, -1, {}) > 0
end
type_prompt_line("go /brai")
H.check("S7b a valid mid-line prefix stays highlighted", has_midline_mark() == true)
type_prompt_line("go /braix")
H.check("S7b an invalid mid-line prefix turns plain", has_midline_mark() == false)

H.summary("claude_slash")
