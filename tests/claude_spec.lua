-- tests/claude_spec.lua
-- Drives the REAL lua/utils/claude.lua public surface for the PERSISTENT
-- bidirectional subprocess architecture: binary resolution, stream-json spawn
-- flags, per-turn stream-json user messages over stdin, event dispatch → panel
-- buffer render, banner population, the ask_selection message construction, and
-- on_exit state lifecycle.
-- Run: nvim --headless -u NONE --cmd "set runtimepath+=." -c "luafile tests/claude_spec.lua"
--
-- Architecture note: claude keeps ONE long-lived process per panel session,
-- spawned `claude --print --input-format stream-json --output-format stream-json
-- --verbose --permission-mode <mode> [--model X]`. Each turn is a stream-json
-- `user` message written to stdin via chansend (NOT a CLI positional arg). So
-- the tests capture the jobstart argv to inspect the spawn flags, capture
-- chansend payloads to inspect the messages, and feed stream-json through the
-- captured on_stdout callback to drive the renderer.

local H = dofile("tests/helpers.lua")
H.stub_project_root("/tmp")

-- ── Subprocess infrastructure stubs ──────────────────────────────────────────
--
-- Capture the on_stdout/on_exit callbacks and the full argv of every jobstart,
-- plus every chansend payload, so tests can (a) assert the spawn flags, (b)
-- assert the per-turn messages, and (c) feed synthetic stream-json events
-- without spawning a real process.

local captured_stdout_cb = nil
local captured_exit_cb   = nil
local jobstart_calls     = {}   -- list of argv tables, one per spawn
local chansend_calls     = {}   -- list of { job, data } payloads

vim.fn.jobstart = function(cmd, opts)
  table.insert(jobstart_calls, cmd)
  captured_stdout_cb = opts.on_stdout
  captured_exit_cb   = opts.on_exit
  return 99  -- fake job_id; > 0 means success
end
vim.fn.jobstop = function() end
vim.fn.chansend = function(job, data)
  table.insert(chansend_calls, { job = job, data = data })
  return #data
end
vim.fn.chanclose = function() end

-- ── Module stubs ──────────────────────────────────────────────────────────────

-- term_layout: place_vertical does window ops irrelevant to these tests.
package.loaded["utils.term_layout"] = {
  place_vertical = function() end,
}

-- claude_diff: on_panel_open would register FileChangedShell autocmds that
-- could interfere with the stream-json tests. Stub it out; the diff module
-- has its own spec (claude_diff_spec.lua).
package.loaded["utils.claude_diff"] = {
  on_panel_open  = function() end,
  on_panel_close = function() end,
  on_diff_open   = function() end,
  on_diff_close  = function() end,
}

-- opencode: the mutex check in claude.toggle() does pcall(require, "utils.opencode").
-- Return a stub with opencode_active=false so the mutex branch is skipped.
package.loaded["utils.opencode"] = {
  state  = { opencode_active = false },
  toggle = function() end,
}

-- ── Load module under test ────────────────────────────────────────────────────

local claude = require("utils.claude")
claude.setup({ width_pct = 0.40 })

-- Patch is_available: the real binary may not be installed on the test machine.
claude.is_available = function() return true end

-- Drive the input float headlessly. The real _open_chat_float opens an
-- interactive nvim_open_win prompt buffer; the stub invokes the callback
-- synchronously with whatever `next_answer` is set to (nil = user cancelled).
local next_answer = nil
claude._open_chat_float = function(_title, cb) cb(next_answer) end

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- Feed a stream-json event through the captured stdout callback and wait for
-- the vim.schedule(dispatch) call to fire so the panel buffer is updated.
-- Neovim's jobstart strips newlines and delivers a complete line as the list
-- { line, "" } (the trailing "" is the empty next-line tail). We must mirror
-- that exactly — appending a literal "\n" would NOT match real delivery.
local function feed(ev)
  local line = vim.json.encode(ev)
  captured_stdout_cb(99, { line, "" }, "stdout")
  vim.wait(50)
end

-- Read all panel buffer lines as a single pipe-joined string for easy matching.
local function panel_text()
  local buf = claude.state.panel_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return "" end
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "|")
end

-- argv of the most recent jobstart spawn.
local function last_argv() return jobstart_calls[#jobstart_calls] end

-- The text of the most recently sent stream-json user message (decoded from the
-- last chansend payload). Returns nil if nothing was sent or it wasn't a user
-- message (e.g. a control_request).
local function last_sent_text()
  local last = chansend_calls[#chansend_calls]
  if not last then return nil end
  local ok, ev = pcall(vim.json.decode, last.data)
  if not ok or type(ev) ~= "table" then return nil end
  if ev.type ~= "user" then return nil end
  return ev.message.content[1].text
end

local function argv_contains(argv, val)
  for _, a in ipairs(argv or {}) do if a == val then return true end end
  return false
end

-- Trigger a real send through the public input path. Clears only the in-flight
-- "working" guard (mirrors a prior turn having ended). Does NOT clear job_id —
-- the persistent process is reused across turns, so the second send must NOT
-- respawn. Tests that want a fresh spawn null job_id explicitly.
local function user_send(text)
  claude.state.working = false
  next_answer = text
  claude.prompt_input()
  vim.wait(20)
end

-- Set visual-selection marks manually (mirrors opencode_spec.lua).
local function with_selection(lines, s_line, s_col, e_line, e_col, sel_mode)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.o.selection = sel_mode or "inclusive"
  vim.fn.setpos("'<", { buf, s_line, s_col, 0 })
  vim.fn.setpos("'>", { buf, e_line, e_col, 0 })
  return buf
end

-- ── T1: Binary resolution ─────────────────────────────────────────────────────

H.check("T1 CLAUDE_BIN expands to full path",
  claude.CLAUDE_BIN == vim.fn.expand("~/.local/bin/claude"),
  "got: " .. claude.CLAUDE_BIN)

local real_available = claude.is_available
claude.is_available = function() return vim.fn.executable(claude.CLAUDE_BIN) == 1 end
H.check("T1 is_available returns bool", type(claude.is_available()) == "boolean")
claude.is_available = real_available  -- restore stub

-- ── T2: State table shape ─────────────────────────────────────────────────────

H.check("T2 state.claude_active starts false", claude.state.claude_active == false)
H.check("T2 state.job_id starts nil",          claude.state.job_id == nil)
H.check("T2 state.session_id starts nil",       claude.state.session_id == nil)
H.check("T2 state.panel_buf starts nil",        claude.state.panel_buf == nil)

-- ── T3: toggle() opens the panel but does NOT spawn (per-message arch) ─────────
-- The panel anchors to the live cwd (vim.fn.getcwd()), so pin it to a known dir.

vim.cmd("cd /tmp")
claude.toggle()
vim.wait(50)

H.check("T3 no subprocess spawned by toggle",   claude.state.job_id == nil
  and #jobstart_calls == 0)
H.check("T3 claude_active true after toggle",   claude.state.claude_active == true)
H.check("T3 panel_buf created",                 claude.state.panel_buf ~= nil
  and vim.api.nvim_buf_is_valid(claude.state.panel_buf))
H.check("T3 panel_buf is nomodifiable",
  not vim.bo[claude.state.panel_buf].modifiable)
-- Cold-start banner renders the glyph + the cwd line before any model is known.
H.check("T3 cold banner glyph present",         panel_text():match("▐▛███▜▌") ~= nil,
  panel_text())
H.check("T3 cold banner cwd present",           panel_text():match("/tmp") ~= nil,
  panel_text())

-- ── T4: first send spawns the persistent stream-json process ──────────────────

claude.state.job_id = nil   -- ensure a clean first spawn
local spawns_before = #jobstart_calls
user_send("hello claude")
H.check("T4 first send spawns subprocess",      claude.state.job_id == 99)
H.check("T4 stdout callback captured",          captured_stdout_cb ~= nil)
local a4 = last_argv()
H.check("T4 spawn uses stream-json input mode",
  argv_contains(a4, "--input-format") and argv_contains(a4, "stream-json"), table.concat(a4, " "))
H.check("T4 spawn carries --print + permission-mode default",
  argv_contains(a4, "--print") and argv_contains(a4, "default"), table.concat(a4, " "))
H.check("T4 spawn carries --permission-prompt-tool stdio (permission gate)",
  argv_contains(a4, "--permission-prompt-tool") and argv_contains(a4, "stdio"),
  table.concat(a4, " "))
H.check("T4 spawn has NO positional message / session flags",
  not argv_contains(a4, "hello claude")
  and not argv_contains(a4, "--session-id")
  and not argv_contains(a4, "--resume"), table.concat(a4, " "))
H.check("T4 message sent as stream-json over stdin",
  last_sent_text() == "hello claude", tostring(last_sent_text()))
H.check("T4 working flag set during send",       claude.state.working == true)

-- ── T5: second send REUSES the same process (no respawn) ──────────────────────

user_send("second message")
H.check("T5 second send does NOT respawn",       #jobstart_calls == spawns_before + 1,
  "spawns=" .. tostring(#jobstart_calls) .. " expected=" .. tostring(spawns_before + 1))
H.check("T5 process handle unchanged",           claude.state.job_id == 99)
H.check("T5 second message sent as stream-json over stdin",
  last_sent_text() == "second message", tostring(last_sent_text()))

-- ── T6: system/init event → banner model + version filled ─────────────────────
-- Friendly name is rendered (NOT the raw model id), version appears on line 0.

feed({ type = "system", subtype = "init", model = "claude-sonnet-4-6", claude_code_version = "1.2.0" })

local banner_text = panel_text()
H.check("T6 banner line1 glyph present",  banner_text:match("▐▛███▜▌") ~= nil, banner_text)
H.check("T6 banner line2 belly present",  banner_text:match("▝▜█████▛▘") ~= nil, banner_text)
H.check("T6 banner line3 feet present",   banner_text:match("▘▘ ▝▝") ~= nil, banner_text)
H.check("T6 friendly model name in banner", banner_text:match("Sonnet 4%.6") ~= nil, banner_text)
H.check("T6 raw model id NOT shown",      banner_text:match("claude%-sonnet%-4%-6") == nil, banner_text)
H.check("T6 version in banner",           banner_text:match("v1%.2%.0") ~= nil, banner_text)
H.check("T6 system_ready flipped",        claude.state.system_ready == true)

-- ── T7: assistant text event → prose rendered ─────────────────────────────────

local lines_before = vim.api.nvim_buf_line_count(claude.state.panel_buf)
feed({ type = "assistant", message = { content = {
  { type = "text", text = "This is assistant prose." }
} } })
H.check("T7 prose appended to panel buffer",
  vim.api.nvim_buf_line_count(claude.state.panel_buf) > lines_before)
H.check("T7 prose text in buffer",
  panel_text():match("This is assistant prose") ~= nil, panel_text())

-- ── T8: tool_use event → tool line rendered ───────────────────────────────────

lines_before = vim.api.nvim_buf_line_count(claude.state.panel_buf)
feed({ type = "assistant", message = { content = {
  { type = "tool_use", name = "Read", input = { file_path = "lua/utils/claude.lua" } }
} } })
H.check("T8 tool line appended",
  vim.api.nvim_buf_line_count(claude.state.panel_buf) > lines_before)
H.check("T8 tool verb and target in buffer",
  panel_text():match("Reading.*claude%.lua") ~= nil, panel_text())

-- ── T9: result event → no trailing separator + working cleared ───────────────
-- The turn separator is drawn at the TOP of the NEXT turn (by render_user), not
-- after the result — a response never ends with a trailing divider. The result
-- text is also NOT echoed (it duplicates the prose and can contain newlines that
-- crash nvim_buf_set_lines).

claude.state.working = true
lines_before = vim.api.nvim_buf_line_count(claude.state.panel_buf)
feed({ type = "result", result = "Done." })
H.check("T9 result appends nothing (no trailing separator)",
  vim.api.nvim_buf_line_count(claude.state.panel_buf) == lines_before, panel_text())
H.check("T9 result text NOT echoed (no duplicate, no crash)",
  panel_text():match("%[result%]") == nil, panel_text())
H.check("T9 working cleared on result", claude.state.working == false)
-- The earlier turns (T4/T5 sends) each placed a separator above their ❯ echo.
-- panel_text() joins buffer lines with "|", so an all-dash line immediately
-- preceding an echo line reads as "─…─|❯".
H.check("T9 turn separator sits above the user echo",
  panel_text():match("─|❯") ~= nil, panel_text())

-- Result with embedded newlines must not crash render (regression: the old
-- code passed multi-line text straight to nvim_buf_set_lines).
claude.state.working = true
local ok_multiline = pcall(feed, { type = "result", result = "line one\nline two" })
H.check("T9 multi-line result does not crash", ok_multiline)

-- ── T10: ask_selection message construction (stream-json over stdin) ──────────
-- Format: "question\n\n```\nselection\n```" sent as the turn's stream-json user
-- message (not a CLI positional arg).

claude.state.job_id       = nil
claude.state.working      = false
claude.state.diff_pending = false
local sends_before = #chansend_calls

next_answer = "explain this"
with_selection({ "local x = 42" }, 1, 1, 1, 12)
claude.ask_selection()
vim.wait(100, function() return #chansend_calls > sends_before end)

H.check("T10 ask_selection sends one message",
  #chansend_calls == sends_before + 1, "sends=" .. (#chansend_calls - sends_before))
H.check("T10 ask_selection message is fenced selection",
  last_sent_text() == "explain this\n\n```\nlocal x = 42\n```",
  vim.inspect(last_sent_text()))

-- ── T11: ask_selection — selection=exclusive trims the trailing column ────────

claude.state.job_id  = nil
claude.state.working = false
sends_before = #chansend_calls
next_answer = "q"
with_selection({ "world foo" }, 1, 1, 1, 6, "exclusive")
claude.ask_selection()
vim.wait(100, function() return #chansend_calls > sends_before end)
H.check("T11 exclusive end col trimmed — no trailing space",
  last_sent_text() == "q\n\n```\nworld\n```",
  vim.inspect(last_sent_text()))
vim.o.selection = "inclusive"

-- ── T12: on_exit resets state (clean exit, code 0) ────────────────────────────

claude.state.job_id = 99
H.check("T12 job_id non-nil before exit", claude.state.job_id ~= nil)
captured_exit_cb(99, 0, "exit")  -- simulate clean exit (code=0)
vim.wait(50)
H.check("T12 job_id cleared on exit",        claude.state.job_id == nil)
H.check("T12 system_ready cleared on exit",  claude.state.system_ready == false)
-- Clean exit (0/143/-1) keeps the panel open for the next turn.
H.check("T12 panel stays active on clean exit", claude.state.claude_active == true)

-- ── T13: availability guard — toggle/ask_selection no-op when binary missing ──

claude.is_available = function() return false end
claude.state.job_id = nil
local calls_guard = #jobstart_calls
claude.toggle()
vim.wait(50)
H.check("T13 no spawn when binary unavailable", #jobstart_calls == calls_guard)

next_answer = "ignored"
claude.ask_selection()
vim.wait(50)
H.check("T13 ask_selection is no-op when binary unavailable",
  #jobstart_calls == calls_guard)
claude.is_available = function() return true end  -- restore

-- ── T14: chunk accumulation — event split across two stdout chunks ────────────
-- The JSON line-buffer must reassemble lines that arrive in separate chunks.

claude.state.system_ready = true
claude.state.job_id       = 99

local full_line = vim.json.encode({
  type = "assistant",
  message = { content = { { type = "text", text = "chunk-test" } } }
})
local mid   = math.floor(#full_line / 2)
local part1 = full_line:sub(1, mid)
local part2 = full_line:sub(mid + 1)

local before_count = vim.api.nvim_buf_line_count(claude.state.panel_buf)
-- Chunk 1: a partial line, no newline yet → Neovim delivers { part1 }.
captured_stdout_cb(99, { part1 }, "stdout")
vim.wait(20)
-- Chunk 2: completes the line → Neovim delivers { part2, "" } (empty tail).
captured_stdout_cb(99, { part2, "" }, "stdout")
vim.wait(50)
local after_count = vim.api.nvim_buf_line_count(claude.state.panel_buf)
H.check("T14 split-chunk event reassembled + rendered",
  after_count > before_count,
  "before=" .. before_count .. " after=" .. after_count)
H.check("T14 chunk-test text rendered",
  panel_text():match("chunk%-test") ~= nil, panel_text())

-- ── T15: type-ahead queue — submit while working enqueues, drains on turn end ──

claude.state.diff_pending = false
claude.state.queue        = {}
claude.state.working      = true     -- a turn is in flight
claude.state.job_id       = 99
local q_sends = #chansend_calls

next_answer = "queued msg"
claude.prompt_input()                -- working → should enqueue, not send
vim.wait(20)
H.check("T15 message queued while working",
  #claude.state.queue == 1 and claude.state.queue[1] == "queued msg",
  vim.inspect(claude.state.queue))
H.check("T15 queued message not sent yet", #chansend_calls == q_sends)

feed({ type = "result", result = "done" })  -- turn ends → drain queue
vim.wait(50)
H.check("T15 queue drained on turn end", #claude.state.queue == 0,
  vim.inspect(claude.state.queue))
H.check("T15 queued message sent after turn", last_sent_text() == "queued msg",
  tostring(last_sent_text()))
H.check("T15 working re-armed for the drained turn", claude.state.working == true)

-- ── T16: can_use_tool permission round-trip (--permission-prompt-tool stdio) ──
-- The CLI asks permission via a control_request{subtype:"can_use_tool"} on
-- stdout; dispatch must reply with a control_response{behavior:"allow",...} on
-- stdin (chansend), echoing request.input as updatedInput and the SAME
-- request_id. Edits auto-allow (they stay vimdiff); non-edits auto-allow for now
-- (step-4 card UI pending) but still must complete the round-trip.

-- Decode the most recent chansend payload as a control_response (or nil).
local function last_control_response()
  local last = chansend_calls[#chansend_calls]
  if not last then return nil end
  local ok, ev = pcall(vim.json.decode, last.data)
  if not ok or type(ev) ~= "table" or ev.type ~= "control_response" then return nil end
  return ev
end

claude.state.job_id = 99

-- Non-edit tool: WebFetch needs permission.
feed({
  type       = "control_request",
  request_id = "req-web-1",
  request    = {
    subtype   = "can_use_tool",
    tool_name = "WebFetch",
    input     = { url = "https://example.com" },
  },
})
local r1 = last_control_response()
H.check("T16 non-edit can_use_tool gets a control_response",
  r1 ~= nil, tostring(r1 and "ok"))
H.check("T16 response echoes the request_id",
  r1 and r1.response and r1.response.request_id == "req-web-1",
  vim.inspect(r1))
H.check("T16 response allows the tool",
  r1 and r1.response and r1.response.response
    and r1.response.response.behavior == "allow", vim.inspect(r1))
H.check("T16 response echoes input as updatedInput",
  r1 and r1.response.response.updatedInput
    and r1.response.response.updatedInput.url == "https://example.com",
  vim.inspect(r1))

-- Edit tool: auto-allowed so the FileChangedShell+vimdiff flow owns it.
feed({
  type       = "control_request",
  request_id = "req-edit-1",
  request    = {
    subtype   = "can_use_tool",
    tool_name = "Edit",
    input     = { file_path = "/tmp/x.lua" },
  },
})
local r2 = last_control_response()
H.check("T16 edit tool auto-allowed (kept for vimdiff)",
  r2 and r2.response.request_id == "req-edit-1"
    and r2.response.response.behavior == "allow", vim.inspect(r2))

H.summary("claude")
