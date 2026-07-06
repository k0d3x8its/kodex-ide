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
-- prewrite_calls records open_prewrite(path, proposed) invocations from the
-- Issue-B gate; prewrite_result is what the stub reports back (true = "diff is
-- up, hold the request", false = "couldn't show it, fall back to auto-allow").
-- The REAL open_prewrite (windows, accept/reject routing) is covered in
-- claude_diff_spec.lua; here we test claude.lua's side of the contract.
local prewrite_calls  = {}
local prewrite_result = true
package.loaded["utils.claude_diff"] = {
  on_panel_open  = function() end,
  on_panel_close = function() end,
  on_diff_open   = function() end,
  on_diff_close  = function() end,
  watch          = function() end,
  poll           = function() end,
  open_prewrite  = function(path, proposed)
    table.insert(prewrite_calls, { path = path, proposed = proposed })
    return prewrite_result
  end,
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
-- ask_selection now uses a SEPARATE selection-anchored float; stub it the same
-- way (synchronous callback) so T10/T11 drive it without an interactive window.
claude._open_selection_float = function(_title, cb) cb(next_answer) end

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
H.check("T4 default spawn omits --effort (level unset)",
  not argv_contains(a4, "--effort"), table.concat(a4, " "))
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

-- ── T9: result event → churn done-line + no trailing separator + working clear ─
-- The result text is NOT echoed (it duplicates the prose and can contain newlines
-- that crash nvim_buf_set_lines). Instead a "✻ <word> for <time>" done line is
-- appended (the official TUI's done state). The turn separator is drawn at the TOP
-- of the NEXT turn (by render_user), never trailing the response.

claude.state.working = true
lines_before = vim.api.nvim_buf_line_count(claude.state.panel_buf)
feed({ type = "result", result = "Done." })
H.check("T9 result appends the '✻ … for <time>' churn done-line",
  panel_text():match("✻ %a+ for ") ~= nil, panel_text())
H.check("T9 result text NOT echoed (no duplicate, no crash)",
  panel_text():match("Done%.") == nil, panel_text())
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

-- ── T16: can_use_tool gate — cards for non-edits, auto-allow for edits ────────
-- The CLI asks permission via control_request{subtype:"can_use_tool"} on stdout.
-- Non-edit tools render an interactive card and WAIT (no control_response until
-- the user chooses). Edit tools auto-allow immediately (they stay vimdiff). The
-- user's choice (T17) sends the control_response on stdin.

-- Decode the most recent chansend payload as a control_response (or nil).
local function last_control_response()
  local last = chansend_calls[#chansend_calls]
  if not last then return nil end
  local ok, ev = pcall(vim.json.decode, last.data)
  if not ok or type(ev) ~= "table" or ev.type ~= "control_response" then return nil end
  return ev
end

claude.state.job_id = 99
claude.state.working = true   -- a turn is in flight when a tool asks permission

-- Non-edit tool with no rule suggestions → card with [Allow once] [Reject].
local sends_b = #chansend_calls
feed({
  type       = "control_request",
  request_id = "req-web-1",
  request    = {
    subtype   = "can_use_tool",
    tool_name = "WebFetch",
    input     = { url = "https://example.com" },
  },
})
H.check("T16 non-edit tool shows a card (no auto control_response)",
  #chansend_calls == sends_b, "sends delta=" .. (#chansend_calls - sends_b))
H.check("T16 card state armed (state.perm set)",
  claude.state.perm ~= nil and claude.state.perm.request_id == "req-web-1",
  vim.inspect(claude.state.perm))
H.check("T16 no rules → 2 options (Allow once, Reject)",
  claude.state.perm and #claude.state.perm.options == 2
    and claude.state.perm.options[1].kind == "once"
    and claude.state.perm.options[2].kind == "deny",
  vim.inspect(claude.state.perm and claude.state.perm.options))

-- Edit tool with NO old_string: unreconstructable for the pre-write gate (T20+),
-- so it falls back to auto-allow + the post-write FileChangedShell+vimdiff flow.
-- Must NOT disturb the pending card (cards are one-at-a-time; edits never queue one).
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

-- ── T17: card resolution — Allow once / Allow always (persists) / Reject ──────

-- Allow once → control_response allow, echoes request_id + input, NO persist.
claude._resolve_permission("once")
local r3 = last_control_response()
H.check("T17 allow-once sends allow with echoed request_id + input",
  r3 and r3.response.request_id == "req-web-1"
    and r3.response.response.behavior == "allow"
    and r3.response.response.updatedInput.url == "https://example.com",
  vim.inspect(r3))
H.check("T17 allow-once does NOT persist a rule (no updatedPermissions)",
  r3 and r3.response.response.updatedPermissions == nil, vim.inspect(r3))
H.check("T17 card cleared after resolve (state.perm nil)",
  claude.state.perm == nil, vim.inspect(claude.state.perm))

-- Tool WITH rule suggestions → card offers Allow always; choosing it persists.
local suggestions = { {
  type = "addRules", destination = "localSettings", behavior = "allow",
  rules = { { toolName = "Bash", ruleContent = "ls:*" } },
} }
feed({
  type       = "control_request",
  request_id = "req-bash-1",
  request    = {
    subtype                = "can_use_tool",
    tool_name              = "Bash",
    input                  = { command = "ls" },
    permission_suggestions = suggestions,
  },
})
H.check("T17 rules present → 3 options incl. Allow always",
  claude.state.perm and #claude.state.perm.options == 3
    and claude.state.perm.options[2].kind == "always",
  vim.inspect(claude.state.perm and claude.state.perm.options))
claude._resolve_permission("always")
local r4 = last_control_response()
H.check("T17 allow-always persists the rule (updatedPermissions = suggestions)",
  r4 and r4.response.response.behavior == "allow"
    and type(r4.response.response.updatedPermissions) == "table"
    and r4.response.response.updatedPermissions[1].rules[1].ruleContent == "ls:*",
  vim.inspect(r4))

-- Reject → control_response deny.
feed({
  type       = "control_request",
  request_id = "req-bash-2",
  request    = {
    subtype   = "can_use_tool",
    tool_name = "Bash",
    input     = { command = "rm -rf /" },
  },
})
claude._resolve_permission("deny")
local r5 = last_control_response()
H.check("T17 reject sends deny",
  r5 and r5.response.request_id == "req-bash-2"
    and r5.response.response.behavior == "deny", vim.inspect(r5))

-- ── T18: AskUserQuestion card — vertical selector, answers map round-trip ─────
-- AskUserQuestion rides the SAME can_use_tool gate but is NOT allow/reject: it
-- carries up to 4 questions and the pick rides back in updatedInput.answers (keyed
-- by question TEXT). The card steps through the N questions, then sends ONE
-- control_response. (.work/FINDINGS.md § Q-ASK)

claude.state.working = true

-- Single question → card armed, no auto control_response, NOT routed to a perm card.
local sends_q = #chansend_calls
feed({
  type       = "control_request",
  request_id = "req-ask-1",
  request    = {
    subtype   = "can_use_tool",
    tool_name = "AskUserQuestion",
    input     = { questions = { {
      question    = "Indent style?",
      header      = "Indent",
      multiSelect = false,
      options     = { { label = "Tabs", description = "hard tabs" },
                      { label = "Spaces", description = "soft" } },
    } } },
  },
})
H.check("T18 question tool shows a card (no auto control_response)",
  #chansend_calls == sends_q, "sends delta=" .. (#chansend_calls - sends_q))
H.check("T18 card armed (state.qask set, perm untouched)",
  claude.state.qask ~= nil and claude.state.qask.request_id == "req-ask-1"
    and claude.state.perm == nil, vim.inspect(claude.state.qask))
H.check("T18 one question, index starts at 1",
  claude.state.qask and #claude.state.qask.questions == 1
    and claude.state.qask.qi == 1, vim.inspect(claude.state.qask and claude.state.qask.qi))
-- Card reserves bottom padding so existing output is pushed ABOVE it (not covered).
H.check("T18 card reserves bottom pad (pushes output up)",
  claude.state.pad_rows >= 1, "pad_rows=" .. tostring(claude.state.pad_rows))

-- Move down to option 2 (Spaces), select → allow with answers keyed by text.
claude._move_question_choice(1)
claude._select_question_choice()
local rq = last_control_response()
H.check("T18 select sends allow echoing request_id",
  rq and rq.response.request_id == "req-ask-1"
    and rq.response.response.behavior == "allow", vim.inspect(rq))
H.check("T18 answers map keyed by question TEXT, value = chosen label",
  rq and rq.response.response.updatedInput
    and rq.response.response.updatedInput.answers
    and rq.response.response.updatedInput.answers["Indent style?"] == "Spaces",
  vim.inspect(rq and rq.response.response.updatedInput))
H.check("T18 card cleared after submit (state.qask nil)",
  claude.state.qask == nil, vim.inspect(claude.state.qask))
H.check("T18 bottom pad released after submit",
  claude.state.pad_rows == 0, "pad_rows=" .. tostring(claude.state.pad_rows))

-- reanchor_pad is the fold-toggle hook that re-pins the last line above a reserved
-- pad when a thinking fold's height change moves it (the real lift needs a live
-- screen, so only the no-pad no-op contract is headless-verifiable here).
H.check("T18 _reanchor_pad exported", type(claude._reanchor_pad) == "function",
  type(claude._reanchor_pad))
claude.state.pad_rows = 0
local ok_re = pcall(claude._reanchor_pad)
H.check("T18 _reanchor_pad no-ops with no pad reserved",
  ok_re and claude.state.pad_rows == 0,
  "ok=" .. tostring(ok_re) .. " pad_rows=" .. tostring(claude.state.pad_rows))

-- Multi-question: ALL arrive in one request; first select advances (no response),
-- last select submits ONE response with every answer.
feed({
  type       = "control_request",
  request_id = "req-ask-2",
  request    = {
    subtype   = "can_use_tool",
    tool_name = "AskUserQuestion",
    input     = { questions = {
      { question = "A?", header = "A", multiSelect = false,
        options = { { label = "X" }, { label = "Y" } } },
      { question = "B?", header = "B", multiSelect = false,
        options = { { label = "P" }, { label = "Q" } } },
    } },
  },
})
local sends_multi = #chansend_calls
claude._select_question_choice()          -- answer Q1 = X (default choice 1)
H.check("T18 first of two questions does NOT submit yet",
  #chansend_calls == sends_multi and claude.state.qask ~= nil
    and claude.state.qask.qi == 2, "qi=" .. tostring(claude.state.qask and claude.state.qask.qi))
claude._move_question_choice(1)           -- Q2 choice → Q
claude._select_question_choice()          -- submit
local rq2 = last_control_response()
H.check("T18 multi-question submits ONE response with all answers",
  rq2 and rq2.response.request_id == "req-ask-2"
    and rq2.response.response.updatedInput.answers["A?"] == "X"
    and rq2.response.response.updatedInput.answers["B?"] == "Q",
  vim.inspect(rq2 and rq2.response.response.updatedInput))

-- multiSelect → answer value is an ARRAY of labels.
feed({
  type       = "control_request",
  request_id = "req-ask-3",
  request    = {
    subtype   = "can_use_tool",
    tool_name = "AskUserQuestion",
    input     = { questions = { {
      question = "Colors?", header = "Color", multiSelect = true,
      options  = { { label = "Red" }, { label = "Green" }, { label = "Blue" } },
    } } },
  },
})
claude._toggle_question_choice()          -- Red on (choice 1)
claude._move_question_choice(1)           -- → Green
claude._move_question_choice(1)           -- → Blue
claude._toggle_question_choice()          -- Blue on
claude._select_question_choice()
local rq3 = last_control_response()
local arr = rq3 and rq3.response.response.updatedInput.answers
            and rq3.response.response.updatedInput.answers["Colors?"]
H.check("T18 multiSelect answer is an array of chosen labels",
  type(arr) == "table" and arr[1] == "Red" and arr[2] == "Blue" and #arr == 2,
  vim.inspect(arr))

-- Cancel → allow with NO answers key (the clean dismiss).
feed({
  type       = "control_request",
  request_id = "req-ask-4",
  request    = {
    subtype   = "can_use_tool",
    tool_name = "AskUserQuestion",
    input     = { questions = { {
      question = "Proceed?", header = "Go", multiSelect = false,
      options  = { { label = "Yes" }, { label = "No" } },
    } } },
  },
})
claude._cancel_question()
local rq4 = last_control_response()
H.check("T18 cancel sends allow with NO answers key",
  rq4 and rq4.response.request_id == "req-ask-4"
    and rq4.response.response.behavior == "allow"
    and rq4.response.response.updatedInput.answers == nil, vim.inspect(rq4))

-- ── T19: question-card parity — free nav, Type something, Chat about this ─────

-- Free navigation between questions WITHOUT answering (Tab/⇥ + arrows). Two
-- questions arrive together; moving forward/back must not submit.
feed({
  type       = "control_request",
  request_id = "req-ask-5",
  request    = {
    subtype   = "can_use_tool",
    tool_name = "AskUserQuestion",
    input     = { questions = {
      { question = "One?", header = "1", multiSelect = false,
        options = { { label = "a" }, { label = "b" } } },
      { question = "Two?", header = "2", multiSelect = false,
        options = { { label = "c" }, { label = "d" } } },
    } },
  },
})
local sends_nav = #chansend_calls
claude._next_question()
H.check("T19 next-question moves without answering (no submit)",
  #chansend_calls == sends_nav and claude.state.qask
    and claude.state.qask.qi == 2, "qi=" .. tostring(claude.state.qask and claude.state.qask.qi))
claude._next_question()
H.check("T19 next-question clamps at the last question",
  claude.state.qask and claude.state.qask.qi == 2, "qi=" .. tostring(claude.state.qask and claude.state.qask.qi))
claude._prev_question()
H.check("T19 prev-question moves back without answering",
  #chansend_calls == sends_nav and claude.state.qask
    and claude.state.qask.qi == 1, "qi=" .. tostring(claude.state.qask and claude.state.qask.qi))
claude._cancel_question()   -- tidy up the open card before the next case

-- "Chat about this" (always the last synthetic option) is NOT a dismiss: it denies
-- with a `message` carrying the canned clarify text + the per-question summary (the
-- bundle's `feedback` serializes to `message` on the wire), so the model opens a
-- clarification dialogue. Question has 2 model options → chat is display index 4. No
-- pick was recorded (highlight moves don't answer), so the summary reports
-- "(No answer provided)".
feed({
  type       = "control_request",
  request_id = "req-ask-6",
  request    = {
    subtype   = "can_use_tool",
    tool_name = "AskUserQuestion",
    input     = { questions = { {
      question = "Bail?", header = "B", multiSelect = false,
      options  = { { label = "stay" }, { label = "go" } },
    } } },
  },
})
claude._move_question_choice(1)   -- 2 (go)
claude._move_question_choice(1)   -- 3 (Type something)
claude._move_question_choice(1)   -- 4 (Chat about this)
claude._select_question_choice()
local rq6 = last_control_response()
local fb6 = rq6 and rq6.response.response.message
H.check("T19 'Chat about this' denies (NOT a dismiss), no answers/updatedInput",
  rq6 and rq6.response.request_id == "req-ask-6"
    and rq6.response.response.behavior == "deny"
    and rq6.response.response.updatedInput == nil
    and claude.state.qask == nil, vim.inspect(rq6))
H.check("T19 'Chat about this' deny message carries the canned clarify text + summary",
  type(fb6) == "string"
    and fb6:find("wants to clarify these questions", 1, true)
    and fb6:find("Questions asked:", 1, true)
    and fb6:find('"Bail?"', 1, true), vim.inspect(fb6))

-- "Type something" routes to the custom input (now a dedicated focused float, not
-- vim.ui.input — the old backend drew behind the card). Selecting the row opens the
-- input WITHOUT submitting; the float's <CR> handler then calls _set_question_custom
-- with the typed text, which records it raw (label-match bypassed) + submits.
feed({
  type       = "control_request",
  request_id = "req-ask-7",
  request    = {
    subtype   = "can_use_tool",
    tool_name = "AskUserQuestion",
    input     = { questions = { {
      question = "Freeform?", header = "F", multiSelect = false,
      options  = { { label = "x" }, { label = "y" } },
    } } },
  },
})
claude._move_question_choice(1)   -- 2 (y)
claude._move_question_choice(1)   -- 3 (Type something)
claude._select_question_choice()  -- opens the input float; nothing submitted yet
H.check("T19 'Type something' opens input without submitting",
  claude.state.qask ~= nil, vim.inspect(claude.state.qask))
claude._set_question_custom("frobnicate the widget")  -- float <CR> commit path
local rq7 = last_control_response()
H.check("T19 'Type something' sends the typed text as the answer value",
  rq7 and rq7.response.request_id == "req-ask-7"
    and rq7.response.response.updatedInput.answers
    and rq7.response.response.updatedInput.answers["Freeform?"] == "frobnicate the widget"
    and claude.state.qask == nil,
  vim.inspect(rq7 and rq7.response.response.updatedInput))

-- ── T20: Issue-B pre-write gate — Write/Edit HELD behind a reconstructed diff ──
-- Gated edit tools no longer auto-allow: the can_use_tool request stays open
-- while a diff of the PROPOSED content (from the tool input — nothing on disk
-- yet) is reviewed. Accept releases allow, reject releases deny. Reconstruction
-- failure falls back to the old auto-allow + post-write flow so the CLI never
-- hangs on a gate we can't show.

-- Write: proposed content is the input's `content` verbatim.
local sends_pw = #chansend_calls
feed({
  type       = "control_request",
  request_id = "req-write-1",
  request    = {
    subtype   = "can_use_tool",
    tool_name = "Write",
    input     = { file_path = "/tmp/pw_new.txt", content = "alpha\nbeta" },
  },
})
H.check("T20 gated Write sends NO immediate control_response",
  #chansend_calls == sends_pw, "sends delta=" .. (#chansend_calls - sends_pw))
H.check("T20 pre-write diff opened with the proposed content",
  #prewrite_calls == 1
    and prewrite_calls[1].path == "/tmp/pw_new.txt"
    and table.concat(prewrite_calls[1].proposed, "\n") == "alpha\nbeta",
  vim.inspect(prewrite_calls))
H.check("T20 held request armed (state.prewrite)",
  claude.state.prewrite ~= nil
    and claude.state.prewrite.request_id == "req-write-1",
  vim.inspect(claude.state.prewrite))

-- Accept → allow, echoing the request input back as updatedInput.
claude.on_prewrite_resolve(true)
local rw1 = last_control_response()
H.check("T20 accept releases allow with echoed input",
  rw1 and rw1.response.request_id == "req-write-1"
    and rw1.response.response.behavior == "allow"
    and rw1.response.response.updatedInput.content == "alpha\nbeta",
  vim.inspect(rw1))
H.check("T20 held request cleared after resolve",
  claude.state.prewrite == nil, vim.inspect(claude.state.prewrite))

-- ── T21: Edit reconstruction — old_string→new_string mirrored from disk ───────
local t21 = "/tmp/claude_prewrite_t21.txt"
vim.fn.writefile({ "one foo two", "three foo four", "five" }, t21)

feed({
  type       = "control_request",
  request_id = "req-edit-2",
  request    = {
    subtype   = "can_use_tool",
    tool_name = "Edit",
    input     = { file_path = t21, old_string = "three foo", new_string = "three bar" },
  },
})
local pc = prewrite_calls[#prewrite_calls]
H.check("T21 single replacement reconstructed from disk",
  claude.state.prewrite ~= nil and pc and pc.path == t21
    and table.concat(pc.proposed, "\n") == "one foo two\nthree bar four\nfive",
  vim.inspect(pc and pc.proposed))

-- Reject → deny with a reason; the file was never written so disk is untouched.
claude.on_prewrite_resolve(false)
local re2 = last_control_response()
H.check("T21 reject releases deny with a message",
  re2 and re2.response.request_id == "req-edit-2"
    and re2.response.response.behavior == "deny"
    and type(re2.response.response.message) == "string",
  vim.inspect(re2))
H.check("T21 disk untouched after deny",
  table.concat(vim.fn.readfile(t21), "\n") == "one foo two\nthree foo four\nfive")

-- replace_all: every occurrence replaced, not just the first.
feed({
  type       = "control_request",
  request_id = "req-edit-3",
  request    = {
    subtype   = "can_use_tool",
    tool_name = "Edit",
    input     = { file_path = t21, old_string = "foo",
                  new_string = "baz", replace_all = true },
  },
})
local pc3 = prewrite_calls[#prewrite_calls]
H.check("T21 replace_all reconstructs every occurrence",
  pc3 and table.concat(pc3.proposed, "\n") == "one baz two\nthree baz four\nfive",
  vim.inspect(pc3 and pc3.proposed))
claude.on_prewrite_resolve(false) -- clean up the held request

-- ── T22: gate fallbacks — reconstruction failure / diff already open ──────────
-- old_string absent from the file → can't reconstruct → auto-allow immediately
-- (old post-write contract), nothing held.
feed({
  type       = "control_request",
  request_id = "req-edit-4",
  request    = {
    subtype   = "can_use_tool",
    tool_name = "Edit",
    input     = { file_path = t21, old_string = "NOT THERE", new_string = "x" },
  },
})
local re4 = last_control_response()
H.check("T22 unreconstructable Edit auto-allows (fallback)",
  re4 and re4.response.request_id == "req-edit-4"
    and re4.response.response.behavior == "allow"
    and claude.state.prewrite == nil,
  vim.inspect(re4))

-- open_prewrite says no (a post-write diff is already up) → same fallback.
prewrite_result = false
feed({
  type       = "control_request",
  request_id = "req-write-2",
  request    = {
    subtype   = "can_use_tool",
    tool_name = "Write",
    input     = { file_path = "/tmp/pw_other.txt", content = "x" },
  },
})
local rw2 = last_control_response()
H.check("T22 occupied diff → Write auto-allows (fallback)",
  rw2 and rw2.response.request_id == "req-write-2"
    and rw2.response.response.behavior == "allow"
    and claude.state.prewrite == nil,
  vim.inspect(rw2))
prewrite_result = true
vim.fn.delete(t21)

-- ── T23–T25: Open-buffer awareness (FINDINGS § Q-CTX) ─────────────────────────
-- host_file_of/current_host_file filter to real on-disk file windows; attach
-- does a FULL @<path> inline on the first turn / a file switch (v2b) and a cheap
-- plain-path breadcrumb on same-file repeats, returning a display-path note only
-- on the full inline (for the dim echo line, v2c).

local hostpath = "/tmp/claude_host_" .. tostring(vim.loop.now()) .. ".lua"
vim.fn.writefile({ "-- host file", "local x = 1", "return x" }, hostpath)
local host_abs = vim.fn.fnamemodify(hostpath, ":p")

vim.cmd("tabnew " .. host_abs)           -- clean editor window backed by a real file
local ewin = vim.api.nvim_get_current_win()

local hf = claude._host_file_of(ewin)
H.check("T23 host_file_of returns abs path for a real file",
  type(hf) == "table" and hf.path == host_abs, vim.inspect(hf))

-- nofile scratch buffer → not a host file
local sbuf = vim.api.nvim_create_buf(false, true)   -- buftype=nofile
vim.api.nvim_win_set_buf(ewin, sbuf)
H.check("T23 host_file_of nil for a nofile buffer",
  claude._host_file_of(ewin) == nil)

-- unnamed (never-saved) buffer → not a host file
local ubuf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_win_set_buf(ewin, ubuf)
H.check("T23 host_file_of nil for an unnamed buffer",
  claude._host_file_of(ewin) == nil)

-- current_host_file scans the tabpage and finds the real-file window
vim.cmd("edit " .. host_abs)
H.check("T24 current_host_file finds the open file",
  (claude._current_host_file() or {}).path == host_abs,
  vim.inspect(claude._current_host_file()))

-- attach_host_context (v2): once per FILE (host_ctx_last_path gate), returns
-- (wire, note) where note = the display path when an attach fired this turn.
vim.cmd("edit " .. host_abs)   -- make host_abs the live editor file
claude.state.host_ctx_last_path = nil
claude.state.host_file = { path = host_abs, disp = host_abs }
local w1, n1 = claude._attach_host_context("hello")
H.check("T25 first turn appends @<path> mention",
  w1:find("@" .. host_abs, 1, true) ~= nil and w1:find("hello", 1, true) ~= nil, w1)
local host_disp = vim.fn.fnamemodify(host_abs, ":~:.")
H.check("T25 attach returns the display path as the note", n1 == host_disp, tostring(n1))
H.check("T25 host_ctx_last_path records the attached file",
  claude.state.host_ctx_last_path == host_abs)
local w2, n2 = claude._attach_host_context("second")
H.check("T25 same file gets a plain breadcrumb (path, NO @) and no note",
  w2:find(host_abs, 1, true) ~= nil
    and w2:find("@" .. host_abs, 1, true) == nil
    and w2:find("second", 1, true) ~= nil
    and n2 == nil, w2)

-- v2b: switching to a DIFFERENT file re-attaches its context
local host2 = "/tmp/claude_host2_" .. tostring(vim.loop.now()) .. ".lua"
vim.fn.writefile({ "-- second host", "return 2" }, host2)
local host_abs2 = vim.fn.fnamemodify(host2, ":p")
vim.cmd("edit " .. host_abs2)
local host_disp2 = vim.fn.fnamemodify(host_abs2, ":~:.")
local w2b, n2b = claude._attach_host_context("now this one")
H.check("T25 v2b file switch re-attaches the new file",
  w2b:find("@" .. host_abs2, 1, true) ~= nil and n2b == host_disp2, w2b)
H.check("T25 v2b host_ctx_last_path advanced to the new file",
  claude.state.host_ctx_last_path == host_abs2)
vim.fn.delete(host_abs2)
vim.cmd("edit " .. host_abs)   -- restore the primary host file as the open one

-- no double-attach when the user already referenced the file themselves (still
-- marked seen so later turns stay verbatim)
claude.state.host_ctx_last_path = nil
local w3, n3 = claude._attach_host_context("look at " .. host_abs)
H.check("T25 no double-attach when path already present",
  w3 == "look at " .. host_abs and n3 == nil
    and claude.state.host_ctx_last_path == host_abs)

-- no host file → text is untouched
claude.state.host_ctx_last_path = nil
claude.state.host_file = nil
vim.cmd("tabnew")   -- empty unnamed buffer, no real-file window in this tab
local w4, n4 = claude._attach_host_context("plain")
H.check("T25 attach is a no-op with no open file", w4 == "plain" and n4 == nil)

-- disabled (host_ctx_enabled=false) → no injection even with a file armed
claude.state.host_ctx_last_path = nil
claude.state.host_file = { path = host_abs, disp = host_abs }
claude.state.host_ctx_enabled = false
local w5, n5 = claude._attach_host_context("hi")
H.check("T25 attach is a no-op when open-buffer context is OFF",
  w5 == "hi" and n5 == nil)
claude.state.host_ctx_enabled = true   -- restore

-- v2c: send() drives render_user with the note → a dim "· with @<file>" line
-- appears under the echo when an attach fires this turn.
vim.cmd("edit " .. host_abs)
claude.state.host_ctx_last_path = nil
claude.state.working = false
claude._send("what does this do")
vim.wait(30)
local uecho = panel_text()
H.check("T25 v2c echo shows the dim '· with @file' context note",
  uecho:find("· with @" .. host_disp, 1, true) ~= nil, uecho)

vim.fn.delete(host_abs)

-- ── T26: user echo renders a ```fence as a code block, not literal backticks ───
-- The <leader>cq selection is sent as a fenced block; render_user must show it
-- with the code gutter (▎) and drop the ``` fence rows.
claude.state.working = false
claude.state.host_ctx_enabled = false   -- keep the message verbatim (no @-append)
claude._send("check this\n\n```lua\nlocal y = 7\n```")
vim.wait(30)
local echo = panel_text()
H.check("T26 fenced user message renders a code gutter (▎)",
  echo:find("▎", 1, true) ~= nil, echo)
H.check("T26 fenced user message drops literal ``` rows",
  echo:find("```", 1, true) == nil, echo)
claude.state.host_ctx_enabled = true    -- restore

-- ── T27: /effort — apply level respawns with --effort, statusline + slider ─────
-- apply mechanism mirrors --model: set state.effort + tear down the process so the
-- next send respawns with --effort <level>.
H.check("T27 current_effort defaults to medium when unset",
  (function() claude.state.effort = nil; return claude.current_effort() end)() == "medium")

-- "/effort high" shorthand applies immediately (no slider) and updates the label.
claude.pick_effort("high")
H.check("T27 pick_effort(level) sets state.effort", claude.state.effort == "high")
H.check("T27 current_effort reflects the pick", claude.current_effort() == "high")
H.check("T27 applying a level tears down the live process (respawn on next send)",
  claude.state.job_id == nil)

-- An invalid level is ignored (opens the slider instead of setting garbage).
claude.state.effort = "high"
claude.pick_effort("bogus")
H.check("T27 invalid level does not overwrite the effort", claude.state.effort == "high")
require("utils.claude.effort").close()   -- dismiss the slider the invalid arg opened

-- Next send carries --effort <level>.
claude.state.job_id = nil
claude.state.effort  = "xhigh"
user_send("go")
local ae = last_argv()
H.check("T27 respawn argv carries --effort xhigh",
  argv_contains(ae, "--effort") and argv_contains(ae, "xhigh"), table.concat(ae, " "))

-- The slider modal: open → move → confirm hands back the chosen level.
local effort = require("utils.claude.effort")
local picked
effort.open("medium", function(lvl) picked = lvl end)
H.check("T27 slider opens", effort.active() == true)
effort.close()
H.check("T27 slider closes", effort.active() == false)

H.summary("claude")
