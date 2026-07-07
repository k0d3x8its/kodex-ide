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
H.check("U1 neoclaude subagent header rendered inline in main",
  panel_text():find("● neoclaude(", 1, true) ~= nil, "main buffer should keep the subagent header")

-- ── U2: inner events (parent-tagged) accumulate into the sink AND hit main ─────

local function main_lines() return vim.api.nvim_buf_line_count(claude.state.panel_buf) end

local rows0 = main_lines()
feed({ type = "assistant", parent_tool_use_id = AGENT_ID, message = { content = { {
  type = "tool_use", id = "toolu_bash_1", name = "Bash",
  input = { command = "echo hi" },
} } } })
local rows_after_call = main_lines()
feed({ type = "user", parent_tool_use_id = AGENT_ID, message = { content = { {
  type = "tool_result", tool_use_id = "toolu_bash_1", content = "hello-from-subagent",
} } } })
local rows_after_result = main_lines()

subs = claude.state.subagents
H.check("U2 both inner events accumulated into the sink",
  subs and #subs[1].events == 2, subs and #subs[1].events)
H.check("U2 sink holds the raw inner tool_use event",
  subs and subs[1].events[1].message.content[1].name == "Bash")
-- Inner tool CALLS render as a compact nested one-liner in main (└ connector).
H.check("U2 inner tool call shows as a compact nested one-liner in main",
  panel_text():find("  └ Bash(", 1, true) ~= nil, panel_text())
H.check("U2 inner tool call added exactly one nested row", rows_after_call - rows0 == 1,
  tostring(rows_after_call - rows0))
-- Inner tool RESULT bodies do NOT flood main (they live in the drill-in view only).
H.check("U2 inner tool_result body adds nothing to main", rows_after_result == rows_after_call)
H.check("U2 inner tool_result body is NOT dumped into main",
  panel_text():find("hello-from-subagent", 1, true) == nil, panel_text())

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

-- ── U4b: an inner assistant message reveals the model → header + switcher update ─

feed({ type = "assistant", parent_tool_use_id = "toolu_agent_B", message = {
  model = "claude-fable-5",
  content = { { type = "text", text = "reviewing" } },
} } )
H.check("U4b subagent model captured from its inner message",
  type(claude.state.subagents[2].model) == "string" and claude.state.subagents[2].model ~= "",
  tostring(claude.state.subagents[2].model))
H.check("U4b main header rewritten in place to show the model",
  panel_text():find("● " .. claude.state.subagents[2].model .. "(", 1, true) ~= nil, panel_text())

-- ── U6: the switcher bar renders (auto-opened during capture) ──────────────────

local widgets = require("utils.claude.widgets")
local function bar_lines()
  local b = claude.state.subagent_buf
  return (b and vim.api.nvim_buf_is_valid(b))
    and vim.api.nvim_buf_get_lines(b, 0, -1, false) or {}
end

H.check("U6 switcher window opened on capture",
  claude.state.subagent_win ~= nil and vim.api.nvim_win_is_valid(claude.state.subagent_win))
local bl = bar_lines()
H.check("U6 row 1 is the 'main' pseudo-entry", bl[1] and bl[1]:find("main", 1, true) ~= nil, bl[1])
H.check("U6 main is selected by default (● filled, sel=1)", bl[1] and bl[1]:find("●", 1, true) ~= nil, bl[1])
-- (desc may be truncated to fit a narrow panel — the name column always survives.)
-- (name may be truncated to fit a narrow panel — the prefix always survives.)
H.check("U6 subagent row shows the neoclaude name column (no model yet)",
  bl[2] and bl[2]:find("neoclaud", 1, true) ~= nil, bl[2])
H.check("U6 unselected subagent row uses hollow ○", bl[2] and bl[2]:find("○", 1, true) ~= nil, bl[2])
H.check("U6 completed subagent meta shows token count",
  bl[2] and bl[2]:find("29.4k", 1, true) ~= nil, bl[2])
H.check("U6 one main row + two subagent rows", #bl == 3, tostring(#bl))

-- ── U7: subagent_height reserves space; float_bottom_row lifts above it ─────────

H.check("U7 subagent_height > 0 while the bar is shown", widgets.subagent_height() > 0)
H.check("U7 float_bottom_row lifted by the full bar height",
  widgets.float_bottom_row() == vim.o.lines - 2 - widgets.subagent_height() - widgets.todo_height())

-- ── U8: selection glyph tracks state.subagent_sel ──────────────────────────────

claude.state.subagent_sel = 2
widgets.update_subagent_bar()
bl = bar_lines()
H.check("U8 selecting row 2 fills it (●) and hollows main (○)",
  bl[1] and bl[1]:find("○", 1, true) ~= nil and bl[2] and bl[2]:find("●", 1, true) ~= nil,
  (bl[1] or "") .. " | " .. (bl[2] or ""))
claude.state.subagent_sel = 1

-- ── U9: ↑/↓ navigation moves the selection + clamps ────────────────────────────

claude.state.subagent_sel = 1
H.check("U9 nav down selects row 2", widgets.subagent_nav(1) == true and claude.state.subagent_sel == 2)
H.check("U9 nav down selects row 3", widgets.subagent_nav(1) == true and claude.state.subagent_sel == 3)
H.check("U9 nav down clamps at the last row (3)", widgets.subagent_nav(1) == true and claude.state.subagent_sel == 3)
H.check("U9 nav up returns to row 2", widgets.subagent_nav(-1) == true and claude.state.subagent_sel == 2)

-- ── U9b: ctrl+b cycles the selection AND opens/closes the view in one step ──────

claude.state.subagent_sel = 1
H.check("U9b cycle from main selects sub 1 and opens the view",
  widgets.subagent_cycle() == true and claude.state.subagent_sel == 2
  and claude.state.subagent_view_win ~= nil
  and vim.api.nvim_win_is_valid(claude.state.subagent_view_win))
widgets.subagent_cycle()   -- → sub 2
widgets.subagent_cycle()   -- → main (wraps, closes the view)
H.check("U9b cycle wraps back to main and closes the view",
  claude.state.subagent_sel == 1
  and (claude.state.subagent_view_win == nil
       or not vim.api.nvim_win_is_valid(claude.state.subagent_view_win)))

-- ── U10: Enter opens the drill-in view; main closes it ─────────────────────────

claude.state.subagent_sel = 2   -- subagents[1]
widgets.subagent_enter()
H.check("U10 Enter on a subagent opens the drill-in view",
  claude.state.subagent_view_win ~= nil and vim.api.nvim_win_is_valid(claude.state.subagent_view_win)
  and claude.state.subagent_view == 1)
H.check("U10 a green title tag opens alongside the view",
  claude.state.subagent_tag_win ~= nil and vim.api.nvim_win_is_valid(claude.state.subagent_tag_win))
H.check("U10 the tag shows the subagent title (its description)",
  (vim.api.nvim_buf_get_lines(claude.state.subagent_tag_buf, 0, 1, false)[1] or "")
    :find("Fable review", 1, true) ~= nil,
  vim.api.nvim_buf_get_lines(claude.state.subagent_tag_buf, 0, 1, false)[1])
claude.state.subagent_sel = 1   -- main
widgets.subagent_enter()
H.check("U10 Enter on main closes the drill-in view",
  claude.state.subagent_view == nil
  and (claude.state.subagent_view_win == nil
       or not vim.api.nvim_win_is_valid(claude.state.subagent_view_win)))
H.check("U10 closing the view also closes the tag",
  claude.state.subagent_tag_win == nil
  or not vim.api.nvim_win_is_valid(claude.state.subagent_tag_win))

-- ── U11: the subagent's LIVE buffer streams its inner activity ─────────────────

-- append_subagent_event ran during the U2 feeds → subagents[1].buf is already
-- populated (not a snapshot rendered at open-time), so the drill-in is live.
local sbuf = claude.state.subagents[1].buf
H.check("U11 subagent has its own live buffer", sbuf ~= nil and vim.api.nvim_buf_is_valid(sbuf))
local ev_text = table.concat(vim.api.nvim_buf_get_lines(sbuf, 0, -1, false), "\n")
H.check("U11 live buffer shows the inner Bash tool call",
  ev_text:find("Bash(echo hi", 1, true) ~= nil, ev_text)
H.check("U11 live buffer shows the tool result body (kept out of main, shown here)",
  ev_text:find("hello-from-subagent", 1, true) ~= nil)
-- A further inner event appends live (buffer grows without reopening the view).
local before = vim.api.nvim_buf_line_count(sbuf)
widgets.append_subagent_event(claude.state.subagents[1],
  { type = "assistant", message = { content = { {
    type = "tool_use", name = "Read", input = { file_path = "/tmp/x.lua" } } } } })
H.check("U11 live buffer grows as new events stream in",
  vim.api.nvim_buf_line_count(sbuf) > before)

-- ── U11b: main nesting is CAPPED so a chatty subagent can't flood the transcript ─

for k = 1, 8 do
  feed({ type = "assistant", parent_tool_use_id = AGENT_ID, message = { content = { {
    type = "tool_use", id = "bcap" .. k, name = "Bash", input = { command = "echo " .. k },
  } } } })
end
H.check("U11b main caps the nested block with a ctrl+b pointer",
  panel_text():find("… (ctrl+b to view)", 1, true) ~= nil, panel_text())

-- ── U12: a long description truncates so the meta stays visible (overflow fix) ──

claude.state.subagents[2].desc = string.rep("x", 300)   -- subagents[2] is still running
widgets.update_subagent_bar()
local row3 = bar_lines()[3] or ""
H.check("U12 long desc is truncated with an ellipsis", row3:find("…", 1, true) ~= nil, row3)
H.check("U12 status meta ('running') stays visible past the long desc",
  row3:find("running", 1, true) ~= nil, row3)
H.check("U12 the raw 300-char desc is NOT present in full",
  row3:find(string.rep("x", 300), 1, true) == nil)

-- ── U13: auto-dismiss arms only when EVERY subagent is finished ─────────────────

H.check("U13 not all-done while subagents[2] is still running",
  widgets.subagents_all_done() == false)
-- A background agent's parent-turn result is only a launch ack — it must NOT mark
-- the subagent done (else the switcher vanishes while it still runs). Feed one and
-- assert status stays running.
feed({ type = "user", parent_tool_use_id = vim.NIL, message = { content = { {
  type = "tool_result", tool_use_id = "toolu_agent_B",
  content = "Async agent launched successfully.",
} } } })
H.check("U13 launch-ack tool_result does NOT complete a running subagent",
  claude.state.subagents[2].status ~= "completed", claude.state.subagents[2].status)
-- The real terminal signal (system/task_notification, keyed by the Agent id) closes it.
feed({ type = "system", subtype = "task_notification",
  task_id = "task_B", tool_use_id = "toolu_agent_B", status = "completed",
  usage = { total_tokens = 1200, tool_uses = 1, duration_ms = 5000 } })
H.check("U13 task_notification completes the background subagent",
  claude.state.subagents[2].status == "completed", claude.state.subagents[2].status)
H.check("U13 all-done once every subagent is terminal", widgets.subagents_all_done() == true)
H.check("U13 all-done arms the deferred auto-dismiss", claude.state.subagent_dismiss_pending == true)

-- ── U5: mod.reset() drops all subagent sessions + closes the bar ───────────────

claude.reset()
vim.wait(30)
H.check("U5 reset clears state.subagents", claude.state.subagents == nil)
H.check("U5 reset restores subagent_sel to 1", claude.state.subagent_sel == 1)
H.check("U5 reset closes the switcher window",
  claude.state.subagent_win == nil
  or not vim.api.nvim_win_is_valid(claude.state.subagent_win))
H.check("U5 subagent_height back to 0 after reset", widgets.subagent_height() == 0)

H.summary("claude_subagent")
