-- tests/claude_subagent_spec.lua
-- Goal 17.1 — subagent capture + inner-event accumulation + lifecycle (spine, no UI).
-- Proves: an Agent/Task tool_use opens a state.subagents entry; inner events tagged
-- with parent_tool_use_id accumulate into that entry's .events sink AND still render
-- inline in main (Option B); the system/task_* lifecycle links task_id and fills
-- status + usage; mod.reset() drops the sessions. Event shapes mirror the real binary
-- (FINDINGS § Q-SUBAGENT-STREAM, re-probed 2026-07-06).
-- Run: nvim --headless -u NONE --cmd "set runtimepath+=." -c "luafile tests/claude_subagent_spec.lua"

local H = dofile("tests/helpers.lua")
H.stub_project_root("/tmp")

-- ── Subprocess + module stubs (mirror claude_stream_spec.lua) ──────────────────

local captured_stdout_cb = nil
vim.fn.jobstart = function(_, opts)
  captured_stdout_cb = opts.on_stdout
  return 99
end
vim.fn.jobstop  = function() end
vim.fn.chansend = function(_, data) return #data end
vim.fn.chanclose = function() end

package.loaded["utils.term_layout"] = { place_vertical = function() end }
package.loaded["utils.claude_diff"] = {
  on_panel_open = function() end, on_panel_close = function() end,
  on_diff_open  = function() end, on_diff_close  = function() end,
  watch = function() end,
  poll  = function() end,
}
package.loaded["utils.opencode"] = {
  state = { opencode_active = false }, toggle = function() end,
}

local claude = require("utils.claude")
claude.setup({ width_pct = 0.40 })
claude.is_available = function() return true end

-- Feed one stream-json event through the captured stdout callback (JSON round-trip
-- through on_stdout → dispatch), mirroring jobstart's { line, "" } delivery.
local function feed(ev)
  captured_stdout_cb(99, { vim.json.encode(ev), "" }, "stdout")
  vim.wait(30)
end

local function panel_text()
  local buf = claude.state.panel_buf
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

-- ── Open the panel + spawn (capture on_stdout) ─────────────────────────────────

vim.cmd("cd /tmp")
claude.toggle()
vim.wait(30)
H.check("U0 panel buffer created",
  claude.state.panel_buf ~= nil and vim.api.nvim_buf_is_valid(claude.state.panel_buf))
claude._send("kick off a subagent")
vim.wait(30)
H.check("U0 stdout callback captured", captured_stdout_cb ~= nil)

local AGENT_ID = "toolu_agent_A"

-- ── U1: Agent tool_use opens a subagent entry + still renders ● Task in main ────

feed({ type = "assistant", parent_tool_use_id = vim.NIL, message = { content = { {
  type = "tool_use", id = AGENT_ID, name = "Agent",
  input = { description = "Fable review of 15.7", subagent_type = "general-purpose" },
} } } })

local subs = claude.state.subagents
H.check("U1 one subagent captured", type(subs) == "table" and #subs == 1)
H.check("U1 entry keyed on the Agent tool_use id", subs and subs[1].id == AGENT_ID)
H.check("U1 desc taken from input.description",
  subs and subs[1].desc == "Fable review of 15.7", subs and subs[1].desc)
H.check("U1 kind taken from subagent_type",
  subs and subs[1].kind == "general-purpose", subs and subs[1].kind)
H.check("U1 status starts 'running'", subs and subs[1].status == "running")
H.check("U1 events sink starts empty", subs and type(subs[1].events) == "table" and #subs[1].events == 0)
H.check("U1 ● Task header still rendered inline in main",
  panel_text():find("Task(", 1, true) ~= nil, "main buffer should keep the Task block")

-- ── U2: inner events (parent-tagged) accumulate into the sink AND hit main ─────

local main_before = panel_text()
feed({ type = "assistant", parent_tool_use_id = AGENT_ID, message = { content = { {
  type = "tool_use", id = "toolu_bash_1", name = "Bash",
  input = { command = "echo hello-from-subagent" },
} } } })
feed({ type = "user", parent_tool_use_id = AGENT_ID, message = { content = { {
  type = "tool_result", tool_use_id = "toolu_bash_1", content = "hello-from-subagent",
} } } })

subs = claude.state.subagents
H.check("U2 both inner events accumulated into the sink",
  subs and #subs[1].events == 2, subs and #subs[1].events)
H.check("U2 sink holds the raw inner tool_use event",
  subs and subs[1].events[1].message.content[1].name == "Bash")
H.check("U2 inner activity ALSO rendered inline in main (Option B fall-through)",
  #panel_text() > #main_before, "main should grow — inner events aren't hidden")

-- A null-parent event must NOT land in any sink.
feed({ type = "assistant", parent_tool_use_id = vim.NIL, message = { content = { {
  type = "text", text = "main-session prose",
} } } })
H.check("U2 null-parent event does not touch the subagent sink",
  claude.state.subagents[1] and #claude.state.subagents[1].events == 2)

-- ── U3: lifecycle — task_started links task_id, updated→status, notification→usage

feed({ type = "system", subtype = "task_started",
  task_id = "task_A", tool_use_id = AGENT_ID,
  description = "Fable review of 15.7", subagent_type = "general-purpose",
  task_type = "local_agent", prompt = "review the extraction" })
H.check("U3 task_started links task_id onto the entry",
  claude.state.subagents[1].task_id == "task_A", claude.state.subagents[1].task_id)

feed({ type = "system", subtype = "task_updated",
  task_id = "task_A", patch = { status = "completed", end_time = 1783371778940 } })
H.check("U3 task_updated flips status via patch.status (keyed by task_id)",
  claude.state.subagents[1].status == "completed", claude.state.subagents[1].status)

feed({ type = "system", subtype = "task_notification",
  task_id = "task_A", tool_use_id = AGENT_ID, status = "completed",
  summary = "The command output was exactly: hello-from-subagent",
  usage = { total_tokens = 29362, tool_uses = 1, duration_ms = 3721 } })
H.check("U3 task_notification fills usage.total_tokens",
  claude.state.subagents[1].usage and claude.state.subagents[1].usage.total_tokens == 29362)
H.check("U3 task_notification fills the summary",
  type(claude.state.subagents[1].summary) == "string"
  and claude.state.subagents[1].summary:find("hello-from-subagent", 1, true) ~= nil)

-- ── U4: a SECOND subagent gets its own entry (insertion-order index) ───────────

feed({ type = "assistant", parent_tool_use_id = vim.NIL, message = { content = { {
  type = "tool_use", id = "toolu_agent_B", name = "Agent",
  input = { description = "second agent", subagent_type = "code-reviewer" },
} } } })
H.check("U4 second subagent appended at index 2",
  #claude.state.subagents == 2 and claude.state.subagents[2].id == "toolu_agent_B")
feed({ type = "assistant", parent_tool_use_id = "toolu_agent_B", message = { content = { {
  type = "text", text = "child B thinking",
} } } })
H.check("U4 inner event routes to the CORRECT subagent (2, not 1)",
  #claude.state.subagents[2].events == 1 and #claude.state.subagents[1].events == 2)

-- ── U5: mod.reset() drops all subagent sessions ────────────────────────────────

claude.reset()
vim.wait(30)
H.check("U5 reset clears state.subagents", claude.state.subagents == nil)
H.check("U5 reset restores subagent_sel to 1", claude.state.subagent_sel == 1)

H.summary("claude_subagent")
