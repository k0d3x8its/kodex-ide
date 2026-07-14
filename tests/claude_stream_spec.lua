-- tests/claude_stream_spec.lua
-- Goal 13 — "typing" phase signal for the post-request compose gap. Proves the
-- panel does NOT paint raw `text_delta` events (the styled block render is kept),
-- but DOES flip the `typing` flag while deltas arrive so the spinner reads
-- "[… · typing]" through the wait. The styled prose lands once, from the
-- aggregated `assistant` event.
-- Run: nvim --headless -u NONE --cmd "set runtimepath+=." -c "luafile tests/claude_stream_spec.lua"

local H = dofile("tests/helpers.lua")
H.stub_project_root("/tmp")

-- ── Subprocess + module stubs (mirror claude_spec.lua) ────────────────────────

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
  watch = function() end,  -- MG 14.2: dispatch pre-loads edit targets through this
  poll  = function() end,  -- the `user` (tool_result) branch schedules poll()
}
package.loaded["utils.opencode"] = {
  state = { opencode_active = false }, toggle = function() end,
}

local claude = require("utils.claude")
claude.setup({ width_pct = 0.40 })
claude.is_available = function() return true end

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- Feed one stream-json event through the captured stdout callback, mirroring
-- jobstart's newline-stripped { line, "" } delivery (see claude_spec.lua).
local function feed(ev)
  captured_stdout_cb(99, { vim.json.encode(ev), "" }, "stdout")
  vim.wait(30)
end

local function line_count()
  return vim.api.nvim_buf_line_count(claude.state.panel_buf)
end

local function panel_text()
  local buf = claude.state.panel_buf
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

-- Count non-overlapping occurrences of a plain substring across the buffer.
local function count_occurrences(hay, needle)
  local n, i = 0, 1
  while true do
    local s = hay:find(needle, i, true)
    if not s then break end
    n = n + 1
    i = s + #needle
  end
  return n
end

local function block_start(index)
  feed({ type = "stream_event",
    event = { type = "content_block_start", index = index, content_block = { type = "text" } } })
end
local function block_delta(index, text)
  feed({ type = "stream_event",
    event = { type = "content_block_delta", index = index, delta = { type = "text_delta", text = text } } })
end
local function block_stop(index)
  feed({ type = "stream_event", event = { type = "content_block_stop", index = index } })
end
local function aggregated_text(text)
  feed({ type = "assistant", message = { content = { { type = "text", text = text } } } })
end

-- ── Open the panel (creates the buffer; no spawn until first send) ─────────────

vim.cmd("cd /tmp")
claude.toggle()
vim.wait(30)
H.check("S0 panel buffer created",
  claude.state.panel_buf ~= nil and vim.api.nvim_buf_is_valid(claude.state.panel_buf))

-- Send one turn so the persistent process spawns and on_stdout is captured (the
-- panel does NOT spawn until the first message — see claude_spec.lua T3/T4).
claude._send("hello")
vim.wait(30)
H.check("S0 stdout callback captured after first send", captured_stdout_cb ~= nil)
-- Before any content block, the model is computing — the dead band must NOT read
-- as frozen. The animated in-body activity line carries the phase WORD "Typing"
-- (a REAL buffer line, so it shows up in nvim_buf_get_lines; the eol randomizer is
-- virt_text and does NOT). The phase word appears exactly once — here in the body,
-- never duplicated in the randomizer bracket.
H.check("S0 working compute gap paints the in-body 'Typing' activity line",
  panel_text():find("Typing", 1, true) ~= nil, panel_text())

-- ── S1: text deltas DO NOT paint into the buffer ───────────────────────────────
-- The raw text must NOT spit into the panel as it streams; the styled block
-- lands once, from the aggregated `assistant` event (S2).

local FULL = "Composed prose with **bold** here.\nSecond paragraph line."

local before = line_count()
block_start(0)
H.check("S1 content_block_start does not draw", line_count() == before,
  "before=" .. before .. " after_start=" .. line_count())

block_delta(0, "Composed prose ")
block_delta(0, "with **bold** here.\n")
block_delta(0, "Second paragraph line.")
H.check("S1 deltas do NOT paint raw text into the buffer", line_count() == before,
  "before=" .. before .. " after_deltas=" .. line_count())
H.check("S1 no raw delta text present", panel_text():find("Second paragraph line.", 1, true) == nil)
H.check("S1 in-body 'Typing' activity line persists while text streams",
  panel_text():find("Typing", 1, true) ~= nil, panel_text())
block_stop(0)

-- ── S2: aggregated event renders the styled block once ─────────────────────────

aggregated_text(FULL)
H.check("S2 block rendered once on the aggregated event", line_count() > before)
H.check("S2 prose text present, single copy",
  count_occurrences(panel_text(), "Second paragraph line.") == 1,
  "occurrences=" .. count_occurrences(panel_text(), "Second paragraph line."))
H.check("S2 final render is markdown-styled (bold markers stripped)",
  panel_text():find("**bold**", 1, true) == nil and panel_text():find("bold", 1, true) ~= nil)

-- ── S3: a turn with NO deltas still renders the block ──────────────────────────

local s3_before = line_count()
aggregated_text("Aggregated-only answer with no deltas.")
H.check("S3 block still renders without any streaming",
  line_count() > s3_before
    and panel_text():find("Aggregated%-only answer with no deltas%.") ~= nil)

-- ── S4: the randomizer bracket carries NO phase word (timing + tokens only) ────
-- The phase moved OUT of the bracket onto the activity line / cornered block. The
-- bracket keeps the climbing timer and, during thinking, the token count — but
-- never the words "thinking" / "typing" / a tool label. The activity WORD tracks
-- the phase (Thinking during a think block, else Typing).

claude.state.think_start  = vim.loop.now()
claude.state.think_tokens = 111
local lbl = claude._spinner_label() or ""
H.check("S4 bracket shows the token count during thinking", lbl:find("111", 1, true) ~= nil, lbl)
H.check("S4 bracket carries no phase word",
  not lbl:find("thinking", 1, true) and not lbl:find("Typing", 1, true)
    and not lbl:find("typing", 1, true), lbl)
H.check("S4 activity word reflects the thinking phase",
  claude._activity_word() == "Thinking", claude._activity_word())
claude.state.think_start  = nil
claude.state.think_tokens = 0
H.check("S4 activity word is 'Typing' outside thinking/tool",
  claude._activity_word() == "Typing", claude._activity_word())

-- ── S5: in-body activity-line lifecycle ───────────────────────────────────────
-- A REAL animated line (unlike the virt_text hint) paints during the compute gap,
-- is REPLACED by the styled block when content lands, and is cleared for good at
-- the turn's `result`. _send paints it synchronously; the assistant/result events
-- are scheduled (on_stdout defers via vim.schedule), so feed() waits for dispatch.
claude.state.think_start = nil
claude.state.tool_run    = nil
claude._send("second question")     -- start_spinner paints the activity line synchronously
H.check("S5 activity line painted in body during the compute gap",
  panel_text():find("Typing", 1, true) ~= nil, panel_text())

aggregated_text("A styled answer.")
-- The styled block landed; the tick may re-add the activity line BELOW it for the
-- next dead band (correct), so we only assert the block is present here.
H.check("S5 styled block lands from the aggregated event",
  panel_text():find("A styled answer%.") ~= nil, panel_text())

-- result ends the turn: stop_spinner clears the activity line and stops the tick,
-- so no "Typing" line survives once the model is idle.
feed({ type = "result", result = "ok", total_cost_usd = 0.02 })
H.check("S5 result leaves no activity line behind",
  panel_text():find("Typing", 1, true) == nil, panel_text())
H.check("S5 styled block survives the turn end, single copy",
  count_occurrences(panel_text(), "A styled answer.") == 1, panel_text())

-- ── S6: cornered ●/└ tool block (gerund header + change summary) ───────────────
-- An Edit tool_use renders "● Editing <file>" + "  └ Added N lines, removed M".
-- Devicons are absent in headless nvim (no plugin), so file_glyph() returns "" —
-- assert on the text. old "a\nb" → new "a\nB\nc\nd" = added 3, removed 1.
claude.state.think_start = nil
claude.state.tool_run    = nil
feed({ type = "assistant", message = { content = { {
  type = "tool_use", name = "Edit", input = {
    file_path  = "/tmp/foo.lua",
    old_string = "a\nb",
    new_string = "a\nB\nc\nd",
  } } } } })
H.check("S6 cornered tool header rendered",
  panel_text():find("● Editing", 1, true) ~= nil, panel_text())
H.check("S6 cornered detail is the change summary",
  panel_text():find("└ Added 3 lines, removed 1 line", 1, true) ~= nil, panel_text())

-- ── S7: tool_result BODIES render under the tool block ─────────────────────────
-- A `user` event from the CLI carries tool_result blocks; the panel used to drop
-- them. Now the body renders indented + dim, long bodies collapse behind a
-- "… +N lines (ctrl+o to expand)" affordance, is_error bodies flag red.
claude.state.think_start = nil
claude.state.tool_run    = nil

-- Short body (≤ K lines): full body, no affordance.
feed({ type = "user", message = { content = { {
  type = "tool_result", tool_use_id = "t1",
  content = "line-alpha\nline-beta",
} } } })
H.check("S7 short tool_result body rendered",
  panel_text():find("line-alpha", 1, true) ~= nil
    and panel_text():find("line-beta", 1, true) ~= nil, panel_text())
H.check("S7 short body shows NO expand affordance",
  panel_text():find("ctrl+o to expand", 1, true) == nil, panel_text())

-- Long body (> K = 6 lines): first 6 shown, rest collapsed behind the affordance.
feed({ type = "user", message = { content = { {
  type = "tool_result", tool_use_id = "t2",
  content = "r1\nr2\nr3\nr4\nr5\nr6\nr7\nr8\nr9",
} } } })
H.check("S7 long body shows the first K=5 lines",
  panel_text():find("r5", 1, true) ~= nil, panel_text())
H.check("S7 long body hides overflow lines",
  panel_text():find("r6", 1, true) == nil, panel_text())
H.check("S7 long body shows '+4 lines (ctrl+o to expand)'",
  panel_text():find("+4 lines (ctrl+o to expand)", 1, true) ~= nil, panel_text())
H.check("S7 long body stashes the full body on state.tool_results",
  (function()
    local tr = claude.state.tool_results
    local last = tr and tr[#tr]
    return last and #last.body == 9 and last.toggleable == true
      and last.start_mark ~= nil and last.end_mark ~= nil
  end)(), vim.inspect(claude.state.tool_results and claude.state.tool_results[#claude.state.tool_results]))

-- Error body: is_error flagged on the stashed entry (red hl not headless-assertable).
feed({ type = "user", message = { content = { {
  type = "tool_result", tool_use_id = "t3", is_error = true,
  content = "Exit code 1\ncat: nope: No such file or directory",
} } } })
-- Body truncates to one row in the narrow headless panel, so assert on prefixes
-- that survive: "Exit code 1" (short first line) + the "cat:" lead of line 2.
H.check("S7 error body rendered",
  panel_text():find("Exit code 1", 1, true) ~= nil
    and panel_text():find("cat:", 1, true) ~= nil, panel_text())
H.check("S7 error body flagged is_error on the stashed entry",
  (function()
    local tr = claude.state.tool_results
    local last = tr and tr[#tr]
    return last and last.is_error == true
  end)())

-- Empty body: no crash, nothing appended.
local s7_before = line_count()
feed({ type = "user", message = { content = { {
  type = "tool_result", tool_use_id = "t4", content = "",
} } } })
H.check("S7 empty tool_result body appends nothing",
  line_count() == s7_before, "before=" .. s7_before .. " after=" .. line_count())

-- ── S8: <C-o> expand swaps the preview for the full body ───────────────────────
-- A fresh long result (8 lines → 5 shown, 3 hidden). Put the cursor on the block,
-- expand, and confirm the previously-hidden lines appear and the affordance is
-- removed — while a DIFFERENT collapsed block (S7's r-block, "+4 lines") stays
-- collapsed (expand is cursor-scoped, not global).
claude.state.think_start = nil
claude.state.tool_run    = nil
feed({ type = "user", message = { content = { {
  type = "tool_result", tool_use_id = "t5",
  content = "x1\nx2\nx3\nx4\nx5\nx6\nx7\nx8",
} } } })
H.check("S8 preview hides overflow before expand",
  panel_text():find("x8", 1, true) == nil, panel_text())

local x_entry = claude.state.tool_results[#claude.state.tool_results]
local function cursor_on(entry)
  local sp = vim.api.nvim_buf_get_extmark_by_id(
    claude.state.panel_buf, claude.state.tool_result_ns, entry.start_mark, {})
  vim.api.nvim_win_set_cursor(claude.state.panel_win, { sp[1] + 1, 0 })
end

cursor_on(x_entry)
claude.expand_result()
H.check("S8 expand reveals the full body", panel_text():find("x8", 1, true) ~= nil, panel_text())
H.check("S8 entry marked expanded", x_entry.expanded == true)
H.check("S8 a different collapsed block stays collapsed",
  panel_text():find("+4 lines (ctrl+o to expand)", 1, true) ~= nil, panel_text())

-- ── S9: a second <C-o> collapses the block back to the preview ─────────────────
cursor_on(x_entry)
claude.expand_result()
H.check("S9 collapse hides the overflow again",
  panel_text():find("x8", 1, true) == nil, panel_text())
H.check("S9 collapse restores the affordance",
  panel_text():find("+3 lines (ctrl+o to expand)", 1, true) ~= nil, panel_text())
H.check("S9 entry marked collapsed", x_entry.expanded == false)

-- ── S10: Skill tool_use renders "● Skill(<name>)" ──────────────────────────────
-- A Skill invocation is a tool_use name="Skill" with the skill name in input.skill.
-- It used to fall through to a bare "● Skill" (no name); now the header names the
-- skill so the block reads like the CC TUI. The result body ("Successfully loaded
-- skill …") renders via the shared tool_result-body foundation (S7), not here.
claude.state.think_start = nil
claude.state.tool_run    = nil
feed({ type = "assistant", message = { content = { {
  type = "tool_use", name = "Skill", input = { skill = "diagnose" },
} } } })
H.check("S10 Skill header names the skill",
  panel_text():find("● Skill(diagnose)", 1, true) ~= nil, panel_text())

-- ── S11: Grep renders a count header + `└` file list, rewritten from the result ──
-- A Grep tool_use draws a provisional "● Searching…" header; the later tool_result
-- rewrites it to the CC-TUI count form and attaches the matched files (one per `└`
-- corner). The "Found N files" summary line is consumed into the count, not listed.
claude.state.think_start = nil
claude.state.tool_run    = nil
feed({ type = "assistant", message = { content = { {
  type = "tool_use", id = "s1", name = "Grep",
  input = { pattern = "tool_run", path = "lua" },
} } } })
H.check("S11 provisional Searching header drawn at tool_use",
  panel_text():find("● Searching", 1, true) ~= nil, panel_text())
feed({ type = "user", message = { content = { {
  type = "tool_result", tool_use_id = "s1",
  content = "Found 3 files\n/tmp/lua/a.lua\n/tmp/lua/b.lua\n/tmp/lua/c.lua",
} } } })
H.check("S11 header rewritten to the count form",
  panel_text():find("● Searching for 1 pattern, reading 3 files", 1, true) ~= nil, panel_text())
H.check("S11 matched files listed under the header",
  panel_text():find("a.lua", 1, true) ~= nil
    and panel_text():find("c.lua", 1, true) ~= nil, panel_text())
H.check("S11 'Found N files' summary line is not listed",
  panel_text():find("Found 3 files", 1, true) == nil, panel_text())
H.check("S11 provisional header replaced (no lingering ellipsis header)",
  panel_text():find("● Searching…", 1, true) == nil, panel_text())

-- Overflow: > K files → header carries the expand affordance, preview caps at K.
feed({ type = "assistant", message = { content = { {
  type = "tool_use", id = "s2", name = "Grep", input = { pattern = "x" },
} } } })
feed({ type = "user", message = { content = { {
  type = "tool_result", tool_use_id = "s2",
  content = "Found 7 files\nf1.lua\nf2.lua\nf3.lua\nf4.lua\nf5.lua\nf6.lua\nf7.lua",
} } } })
H.check("S11 overflow header carries the expand affordance",
  panel_text():find("reading 7 files (ctrl+o to expand)", 1, true) ~= nil, panel_text())
H.check("S11 overflow preview hides files past K=5",
  panel_text():find("f7.lua", 1, true) == nil, panel_text())

-- No matches: header says so, no file list.
feed({ type = "assistant", message = { content = { {
  type = "tool_use", id = "s3", name = "Grep", input = { pattern = "zzz" },
} } } })
feed({ type = "user", message = { content = { {
  type = "tool_result", tool_use_id = "s3", content = "No files found",
} } } })
H.check("S11 empty result → 'no matches' header",
  panel_text():find("● Searching — no matches", 1, true) ~= nil, panel_text())

-- ── S12: a search-shaped Bash command renders as a Search block ─────────────────
-- Headless claude has no Grep tool, so it searches via Bash. `rg -l` emits a bare
-- file list → count header + `└ file` list (same treatment as the Grep tool).
claude.state.think_start = nil
claude.state.tool_run    = nil
feed({ type = "assistant", message = { content = { {
  type = "tool_use", id = "b1", name = "Bash",
  input = { command = "rg -l render_tool lua/" },
} } } })
H.check("S12 rg draws a Searching header, not Running bash",
  panel_text():find("● Searching", 1, true) ~= nil, panel_text())
feed({ type = "user", message = { content = { {
  type = "tool_result", tool_use_id = "b1",
  content = "lua/utils/claude.lua\nlua/plugins/claude.lua",
} } } })
H.check("S12 rg -l file list → count header",
  panel_text():find("● Searching for 1 pattern, reading 2 files", 1, true) ~= nil, panel_text())
H.check("S12 rg -l lists the files",
  panel_text():find("claude.lua", 1, true) ~= nil, panel_text())

-- ── S13: match-line search (rg without -l) → pattern header + match body ────────
claude.state.tool_run = nil
feed({ type = "assistant", message = { content = { {
  type = "tool_use", id = "b2", name = "Bash",
  input = { command = "rg render_tool lua/utils/claude.lua" },
} } } })
feed({ type = "user", message = { content = { {
  type = "tool_result", tool_use_id = "b2",
  content = "lua/utils/claude.lua:1857:local function render_tool(name, input)",
} } } })
H.check("S13 match-line search names the pattern in the header",
  panel_text():find("● Searching  render_tool", 1, true) ~= nil, panel_text())
-- Body truncates to one row in the narrow headless panel, so assert on the
-- surviving leading prefix of the match line (the tail is ellipsized).
H.check("S13 match-line body rendered",
  panel_text():find("claude.lua:1857", 1, true) ~= nil, panel_text())

-- ── S14: fd/find → "● Listing M files" ─────────────────────────────────────────
claude.state.tool_run = nil
feed({ type = "assistant", message = { content = { {
  type = "tool_use", id = "b3", name = "Bash", input = { command = "fd -e lua" },
} } } })
feed({ type = "user", message = { content = { {
  type = "tool_result", tool_use_id = "b3", content = "a.lua\nb.lua\nc.lua",
} } } })
H.check("S14 fd renders a Listing count header",
  panel_text():find("● Listing 3 files", 1, true) ~= nil, panel_text())

-- ── S15: a non-search Bash command still renders "● Running bash" ───────────────
claude.state.tool_run = nil
feed({ type = "assistant", message = { content = { {
  type = "tool_use", id = "b4", name = "Bash", input = { command = "npm run build" },
} } } })
H.check("S15 non-search Bash is unchanged",
  panel_text():find("● Running bash", 1, true) ~= nil, panel_text())

-- ── S16: Task (subagent) → "● Task(<desc>)" + agent type + result body ─────────
-- The Task tool spawns a subagent; header names the short description, corner
-- names the agent type, and the subagent's final result renders via the
-- foundation (its intermediate activity isn't in the headless stream).
claude.state.think_start = nil
claude.state.tool_run    = nil
feed({ type = "assistant", message = { content = { {
  type = "tool_use", id = "tk1", name = "Task",
  input = { description = "Explore render code", subagent_type = "Explore",
            prompt = "find all render_ functions" },
} } } })
H.check("S16 subagent header brands neoclaude + the description (model fills in later)",
  panel_text():find("● neoclaude(Explore render code)", 1, true) ~= nil, panel_text())
feed({ type = "user", message = { content = { {
  type = "tool_result", tool_use_id = "tk1",
  content = "Found render_tool, render_prose, render_thinking.",
} } } })
H.check("S16 Task result body renders",
  panel_text():find("Found render_tool", 1, true) ~= nil, panel_text())

-- The headless build names the subagent tool "Agent"; it gets the same header.
claude.state.tool_run = nil
feed({ type = "assistant", message = { content = { {
  type = "tool_use", id = "ag1", name = "Agent",
  input = { description = "Audit float layout", subagent_type = "general-purpose" },
} } } })
H.check("S16 Agent tool_use also renders the neoclaude subagent header",
  panel_text():find("● neoclaude(Audit float layout)", 1, true) ~= nil, panel_text())

-- ── S17: TodoWrite drives the bottom task widget, not an inline block ───────────
-- render_todo_lines is pure: header counts + glyph rows + activeForm for the
-- in-progress task + "+N more" cap. Dispatch captures the list and suppresses both
-- the inline tool block and the noisy "Todos have been modified" result body.
local todos = {
  { content = "Add helpers",        status = "completed"   },
  { content = "Fix perm float",     status = "in_progress", activeForm = "Fixing perm float" },
  { content = "Fix question float", status = "pending"     },
  { content = "Refactor chat",      status = "pending"     },
  { content = "Run make test",      status = "pending"     },
}
local tlines = claude._render_todo_lines(todos)
H.check("S17 header counts by status",
  tlines[1] == " 5 tasks (1 done, 1 in progress, 3 open)", tlines[1])
H.check("S17 completed row shows the check glyph",
  tlines[2]:find("✔", 1, true) ~= nil, tlines[2])
H.check("S17 in-progress row uses activeForm",
  tlines[3]:find("Fixing perm float", 1, true) ~= nil, tlines[3])

-- Cap: 10 tasks → header + 7 rows + "… +3 more".
local many = {}
for i = 1, 10 do many[i] = { content = "task " .. i, status = "pending" } end
local mlines = claude._render_todo_lines(many)
H.check("S17 caps the list with a '+N more' tail",
  mlines[#mlines]:find("… +3 more", 1, true) ~= nil, mlines[#mlines])

-- Dispatch: TodoWrite captures the list, renders NO inline tool block.
claude.state.think_start = nil
claude.state.tool_run    = nil
local s17_txt_before = panel_text()
feed({ type = "assistant", message = { content = { {
  type = "tool_use", id = "td1", name = "TodoWrite", input = { todos = todos },
} } } })
H.check("S17 TodoWrite captures the todo list on state",
  claude.state.todos and #claude.state.todos == 5, vim.inspect(claude.state.todos))
H.check("S17 TodoWrite renders no inline tool block",
  panel_text():find("Update Todos", 1, true) == nil
    and panel_text():find("● TodoWrite", 1, true) == nil, panel_text())

-- The TodoWrite result ack is suppressed (widget already reflects the change).
feed({ type = "user", message = { content = { {
  type = "tool_result", tool_use_id = "td1",
  content = "Todos have been modified successfully",
} } } })
H.check("S17 TodoWrite result ack is not rendered",
  panel_text():find("have been modified", 1, true) == nil, panel_text())

-- ── S18: Task* orchestration tools drive the same widget (headless SDK) ─────────
-- The panel's headless claude has NO TodoWrite tool; it tracks a plan via the
-- Task* family. TaskCreate appends one item (id from a running counter matching
-- the CLI's "Task #N"); TaskUpdate mutates one by taskId; deleted removes it.
-- Mirrors the TodoWrite path: no inline block, result ack suppressed.
claude.state.todos    = nil
claude.state.todo_seq = nil
claude.state.think_start, claude.state.tool_run = nil, nil

local function task_create(id, subject, activeForm)
  feed({ type = "assistant", message = { content = { {
    type = "tool_use", id = id, name = "TaskCreate",
    input = { subject = subject, activeForm = activeForm },
  } } } })
end
local function task_update(id, taskId, status)
  feed({ type = "assistant", message = { content = { {
    type = "tool_use", id = id, name = "TaskUpdate",
    input = { taskId = taskId, status = status },
  } } } })
end

task_create("tc1", "Define endpoint",  "Defining endpoint")
task_create("tc2", "Implement handler", "Implementing handler")
task_create("tc3", "Register route")
task_create("tc4", "Write tests")
H.check("S18 TaskCreate appends items with sequential ids",
  claude.state.todos and #claude.state.todos == 4
    and claude.state.todos[1].id == 1 and claude.state.todos[4].id == 4,
  vim.inspect(claude.state.todos))
H.check("S18 created items are pending with subject as content",
  claude.state.todos[3].status == "pending"
    and claude.state.todos[3].content == "Register route",
  vim.inspect(claude.state.todos[3]))
H.check("S18 TaskCreate renders no inline tool block",
  panel_text():find("● TaskCreate", 1, true) == nil
    and panel_text():find("TaskCreate", 1, true) == nil, panel_text())

task_update("tu1", "1", "in_progress")
task_update("tu2", "2", "completed")
H.check("S18 TaskUpdate mutates the task by id",
  claude.state.todos[1].status == "in_progress"
    and claude.state.todos[2].status == "completed",
  vim.inspect(claude.state.todos))

task_update("tu3", "3", "deleted")
H.check("S18 TaskUpdate deleted removes the task",
  #claude.state.todos == 3
    and claude.state.todos[3].content == "Write tests",  -- id 4 shifts down
  vim.inspect(claude.state.todos))

-- The "Task #N created successfully" ack is suppressed (widget already reflects it).
feed({ type = "user", message = { content = { {
  type = "tool_result", tool_use_id = "tc1",
  content = "Task #1 created successfully: Define endpoint",
} } } })
H.check("S18 TaskCreate result ack is not rendered",
  panel_text():find("created successfully", 1, true) == nil, panel_text())

-- REGRESSION: system/init fires once per TURN in stream-json mode, so it must
-- NOT clear the task list (that wiped the widget on the next turn). The reset
-- lives in ensure_process (once per spawn) instead.
local before_n = #claude.state.todos
feed({ type = "system", subtype = "init", model = "claude-haiku",
  claude_code_version = "2.1.195" })
H.check("S18 system/init preserves the task list (per-turn event)",
  claude.state.todos and #claude.state.todos == before_n and before_n == 3,
  vim.inspect(claude.state.todos))

-- Completed-row text span must start AFTER the 1-space pad + glyph + separator
-- space, else the strikethrough covers the space and bleeds a line into the ✔
-- (live-observed). Offset = #PAD(1) + #"✔" + 1 separator.
local _, chls = claude._render_todo_lines({ { content = "done", status = "completed" } })
H.check("S18 completed text span skips the pad+glyph+space (no strike bleed)",
  chls[2] and chls[2][2] and chls[2][2][1] == 1 + #"✔" + 1,
  vim.inspect(chls[2]))

-- plan_complete: the pure all-tasks-done gate (auto-dismiss fires ONLY on this).
H.check("S18 plan_complete is false when any task is unfinished",
  claude._plan_complete({ { status = "completed" }, { status = "pending" } }) == false)
H.check("S18 plan_complete is true only when every task is completed",
  claude._plan_complete({ { status = "completed" }, { status = "completed" } }) == true)
H.check("S18 plan_complete is false for an empty plan",
  claude._plan_complete({}) == false)

-- Behavior: completing ONE of two must NOT arm the dismiss; completing ALL does.
-- (Guards against per-task disappearance — the card only fades when the whole plan
-- is done.)
claude.state.todos, claude.state.todo_seq = nil, nil
claude.state.todo_done_pending = false
task_create("d1", "First")
task_create("d2", "Second")
task_update("du1", "1", "completed")
H.check("S18 completing one of two does NOT arm the dismiss",
  claude.state.todo_done_pending == false, tostring(claude.state.todo_done_pending))
task_update("du2", "2", "completed")
H.check("S18 completing ALL tasks arms the dismiss",
  claude.state.todo_done_pending == true, tostring(claude.state.todo_done_pending))

-- ── S19: taxonomy leftovers — ExitPlanMode, MCP name-strip, WebFetch url ────────
-- Every tool_use must render a coherent gerund block, no bare underscored name.
claude.state.think_start = nil
claude.state.tool_run    = nil

-- ExitPlanMode → "● Plan" header + one-line preview of the proposed plan (input).
feed({ type = "assistant", message = { content = { {
  type = "tool_use", id = "ep1", name = "ExitPlanMode",
  input = { plan = "Step 1: refactor\nStep 2: test" },
} } } })
H.check("S19 ExitPlanMode renders a Plan header",
  panel_text():find("● Plan", 1, true) ~= nil, panel_text())
H.check("S19 ExitPlanMode collapses the multi-line plan to one corner line",
  panel_text():find("Step 1: refactor Step 2: test", 1, true) ~= nil, panel_text())

-- MCP tool `mcp__server__tool` → Skill-style "● MCP(<tool>)" (server dropped) +
-- a `└` corner with the one-line JSON of the call params.
claude.state.tool_run = nil
feed({ type = "assistant", message = { content = { {
  type = "tool_use", id = "mc1", name = "mcp__claude_ai_Notion__notion-create-pages",
  input = { title = "bug" },
} } } })
H.check("S19 MCP wraps the short tool name in MCP()",
  panel_text():find("● MCP(notion-create-pages)", 1, true) ~= nil, panel_text())
H.check("S19 MCP corner shows the one-line param JSON",
  panel_text():find('"title": "bug"', 1, true) ~= nil, panel_text())

-- WebFetch → "● Fetching" with the url as the corner target (url now in the chain).
claude.state.tool_run = nil
feed({ type = "assistant", message = { content = { {
  type = "tool_use", id = "wf1", name = "WebFetch",
  input = { url = "https://example.com/doc", prompt = "summarize" },
} } } })
H.check("S19 WebFetch header is the Fetching gerund",
  panel_text():find("● Fetching", 1, true) ~= nil, panel_text())
H.check("S19 WebFetch corner shows the url",
  panel_text():find("https://example.com/doc", 1, true) ~= nil, panel_text())

-- ── S20: a NEW-file Write renders its content as a numbered, collapsible body ──
-- Write to a nonexistent path gets its own "● Write(<file>)" header + "Wrote N
-- lines to <file>" corner, then the content as a numbered body that collapses past
-- 10 lines behind the "ctrl+o to expand" affordance (no red/green change summary —
-- it's not an Edit). Placed last: it registers a tool_results fold entry + leaves a
-- collapse affordance in the panel, which earlier panel-wide assertions would trip.
claude.state.think_start = nil
claude.state.tool_run    = nil
local wpath = "/tmp/kodex_write_probe_nonexistent.py"
os.remove(wpath)   -- ensure NEW file → numbered-body path (not the accept-time diff)
local wbody = {}
for i = 1, 13 do wbody[i] = "x" .. i .. " = " .. i end
feed({ type = "assistant", message = { content = { {
  type = "tool_use", name = "Write", input = { file_path = wpath, content = table.concat(wbody, "\n") },
} } } })
local wt = panel_text()
H.check("S20 Write header is '● Write <file>' (no parens)",
  wt:find("● Write ", 1, true) ~= nil and wt:find("● Write(", 1, true) == nil, wt)
H.check("S20 corner reads 'Wrote 13 lines to …'", wt:find("Wrote 13 lines to", 1, true) ~= nil, wt)
H.check("S20 numbered content body rendered", wt:find("%f[%d]1%s+x1 = 1") ~= nil, wt)
H.check("S20 overflow collapses behind ctrl+o affordance",
  wt:find("+3 lines (ctrl+o to expand)", 1, true) ~= nil, wt)
H.check("S20 Write shows NO Edit-style change summary",
  wt:find("Added 13 lines", 1, true) == nil, wt)
H.check("S20 Write body stashed as a toggleable 'write' fold entry",
  (function()
    local last = claude.state.tool_results and claude.state.tool_results[#claude.state.tool_results]
    return last and last.kind == "write" and #last.code_lines == 13 and last.toggleable == true
  end)())

-- ── S21: fg-only twin cache survives a colorscheme wipe (#8a regression) ──────
-- A `:colorscheme` runs `:highlight clear`, wiping the ns-0 ClaudeCode*Fg twins
-- the edit-hunk / Write body syntax spans point at. define_highlights() restores
-- the BASE groups on ColorScheme, but the render module caches the derived twins
-- forever — so without invalidation the next render reuses a cached twin NAME
-- pointing at a now-EMPTY group → code renders with no syntax colour. The fix:
-- the ColorScheme autocmd calls render.reset_hunk_fg_cache() so twins re-derive.
local render = require("utils.claude.render")
local function twin_has_fg()
  return not vim.tbl_isempty(vim.api.nvim_get_hl(0, { name = "ClaudeCodeKeywordFg" }))
end
-- Base group present (as define_highlights would leave it); derive the twin once.
vim.api.nvim_set_hl(0, "ClaudeCodeKeyword", { fg = "#FF79C6" })
render._hunk_fg_group("ClaudeCodeKeyword")
H.check("S21 twin derived with fg on first use", twin_has_fg())

-- Simulate the :colorscheme wipe: the twin group is cleared, the base survives
-- (its own ColorScheme handler re-created it). The cache still holds the twin.
vim.api.nvim_set_hl(0, "ClaudeCodeKeywordFg", {})
H.check("S21 :colorscheme wipes the twin group", not twin_has_fg())
render._hunk_fg_group("ClaudeCodeKeyword")   -- cached name returned; NOT re-derived
H.check("S21 stale cache leaves the twin empty (the bug)", not twin_has_fg())

-- The fix: invalidating the cache makes the next derive rebuild the twin.
render.reset_hunk_fg_cache()
render._hunk_fg_group("ClaudeCodeKeyword")
H.check("S21 reset_hunk_fg_cache re-derives the twin with fg", twin_has_fg())

-- ── S22: turn timer pauses while a decision modal is up (Waiting…) ────────────
-- A decision modal blocks the CLI on the USER; the turn clock must freeze so the
-- wait isn't counted (matching the official TUI's "waiting…"). gated() detects any
-- of the modal states; turn_elapsed_ms() subtracts accumulated + in-progress pause.
local core = require("utils.claude.core")

-- gated() is true for EACH decision-modal state, false when none is up.
for _, field in ipairs({ "perm", "prewrite", "qask", "diff_card" }) do
  claude.state.perm, claude.state.prewrite = nil, nil
  claude.state.qask, claude.state.diff_card, claude.state.diff_pending = nil, nil, nil
  claude.state[field] = (field == "diff_pending") and true or {}
  H.check("S22 gated() true when state." .. field .. " is set", claude._gated() == true)
end
claude.state.perm, claude.state.prewrite = nil, nil
claude.state.qask, claude.state.diff_card, claude.state.diff_pending = nil, nil, nil
H.check("S22 gated() false when no modal is up", claude._gated() == false)

-- turn_elapsed_ms excludes the accumulated pause total.
claude.state.turn_t0        = vim.loop.now() - 5000   -- turn started 5s ago
claude.state.turn_paused_ms = 2000                    -- 2s of that was modal-wait
claude.state.pause_t0       = nil
local e1 = core.turn_elapsed_ms()
H.check("S22 elapsed excludes accumulated pause (~3s)", e1 >= 2800 and e1 <= 3200, e1)

-- An IN-PROGRESS pause (pause_t0 set) is also subtracted, live.
claude.state.pause_t0 = vim.loop.now() - 1000         -- currently 1s into a pause
local e2 = core.turn_elapsed_ms()
H.check("S22 elapsed excludes in-progress pause (~2s)", e2 >= 1800 and e2 <= 2200, e2)

-- resume_turn folds the in-progress pause into the total and clears pause_t0.
core.resume_turn()
H.check("S22 resume_turn clears pause_t0", claude.state.pause_t0 == nil)
H.check("S22 resume_turn folds pause into total (~3000ms)",
  claude.state.turn_paused_ms >= 2900 and claude.state.turn_paused_ms <= 3100,
  claude.state.turn_paused_ms)

-- pause_turn is idempotent: a second call keeps the original pause origin.
claude.state.pause_t0 = nil
core.pause_turn(); local first = claude.state.pause_t0
core.pause_turn()
H.check("S22 pause_turn is idempotent (origin preserved)", claude.state.pause_t0 == first)

-- ── S23: advisor strategy render (server_tool_use + advisor_tool_result) ───────
-- The advisor escalation arrives as a `server_tool_use` (name "advisor") header +
-- a separate `advisor_tool_result` body. The advisor MODEL is NOT in the stream —
-- it's labelled from state.advisor_model (the /advisor pick). Shapes captured live
-- (Sonnet executor / Opus advisor). See .work/FINDINGS.md § Q-ADVISOR.
claude.state.think_start   = nil
claude.state.tool_run      = nil
claude.state.advisor_model = "opus"
feed({ type = "assistant", message = { content = { {
  type = "server_tool_use", id = "srvtoolu_1", name = "advisor", input = {},
} } } })
H.check("S23 advisor header labels the tracked advisor model",
  panel_text():find("● Advising using Opus 4.8", 1, true) ~= nil, panel_text())
-- The header marks the consult in-flight, so the compute-phase word reads
-- "Consulting" (not "Typing") until the advice lands.
H.check("S23 in-flight consult sets advisor_pending + 'Consulting' word",
  claude.state.advisor_pending == true and claude._activity_word() == "Consulting",
  tostring(claude.state.advisor_pending) .. " / " .. claude._activity_word())

feed({ type = "assistant", message = { content = { {
  type = "advisor_tool_result", tool_use_id = "srvtoolu_1",
  content = { type = "advisor_result", text = "Consult the protocol, not your notes." },
} } } })
-- Advice arrived → flag clears, word reverts to "Typing" for the executor's resume.
H.check("S23 advice clears advisor_pending + word reverts to 'Typing'",
  claude.state.advisor_pending == false and claude._activity_word() == "Typing",
  tostring(claude.state.advisor_pending) .. " / " .. claude._activity_word())
-- The advice is prose (long paragraph-lines), so the panel collapses it to a fixed
-- one-line summary + green ✔ (always ctrl+o-expandable) rather than a clipped
-- first-K preview. Assert: (1) the canned summary shows, (2) the expand affordance
-- shows, (3) the raw advice is NOT in the collapsed panel but IS stored on the
-- tool_results entry (so ctrl+o can expand to the full, word-wrapped advice).
-- Prefix only: the summary clips to panel width in the narrow test viewport.
H.check("S23 advisor advice collapses to the canned summary line",
  panel_text():find("✔ Advisor has reviewed", 1, true) ~= nil, panel_text())
H.check("S23 advisor collapsed block is expandable (ctrl+o affordance)",
  panel_text():find("ctrl+o to expand", 1, true) ~= nil, panel_text())
H.check("S23 raw advice hidden when collapsed but kept for expansion",
  panel_text():find("Consult the protocol", 1, true) == nil
    and (function()
      local e = claude.state.tool_results and claude.state.tool_results[#claude.state.tool_results]
      return e and e.toggleable and table.concat(e.body, "\n"):find("Consult the protocol", 1, true) ~= nil
    end)(), panel_text())

-- No tracked advisor (nil) → header omits the "using <model>" suffix, no crash.
claude.state.think_start   = nil
claude.state.tool_run      = nil
claude.state.advisor_model = nil
feed({ type = "assistant", message = { content = { {
  type = "server_tool_use", id = "srvtoolu_2", name = "advisor", input = {},
} } } })
-- Assert a STANDALONE "● Advising" line exists (no "using" suffix). Checking the
-- whole buffer for absence of "using" would false-fail on the earlier Opus header,
-- so match an exact line instead.
H.check("S23 header without a tracked model shows bare '● Advising'",
  (function()
    for _, l in ipairs(vim.api.nvim_buf_get_lines(claude.state.panel_buf, 0, -1, false)) do
      if l == "● Advising" then return true end
    end
    return false
  end)(), panel_text())

-- An error result (no usable text) renders the "Advisor unavailable" line.
feed({ type = "assistant", message = { content = { {
  type = "advisor_tool_result", tool_use_id = "srvtoolu_2",
  content = { type = "advisor_result" },   -- no text field
} } } })
H.check("S23 error/empty advisor result shows 'Advisor unavailable'",
  panel_text():find("Advisor unavailable", 1, true) ~= nil, panel_text())

-- ── S24: live thinking-token count collapses to K past 1,100 ───────────────────
-- Below the 1,100 threshold the raw integer shows; at/above it collapses to a
-- one-decimal "K" form (uppercase K, by request). Boundary + representative cases.
H.check("S24 sub-threshold token count stays a raw integer",
  claude._fmt_think_tokens(632) == "632", claude._fmt_think_tokens(632))
H.check("S24 just below 1,100 stays raw",
  claude._fmt_think_tokens(1099) == "1099", claude._fmt_think_tokens(1099))
H.check("S24 exactly 1,100 collapses to 1.1K",
  claude._fmt_think_tokens(1100) == "1.1K", claude._fmt_think_tokens(1100))
H.check("S24 2504 → 2.5K",
  claude._fmt_think_tokens(2504) == "2.5K", claude._fmt_think_tokens(2504))
-- And the spinner bracket actually uses it (not the raw %d anymore).
claude.state.think_start  = vim.loop.now()
claude.state.think_tokens = 2504
local klbl = claude._spinner_label() or ""
H.check("S24 spinner bracket shows the K-form token count",
  klbl:find("2.5K tokens", 1, true) ~= nil, klbl)
claude.state.think_start  = nil
claude.state.think_tokens = 0

-- ── S25: Artifact tool_use header + published-URL result ───────────────────────
-- A publish renders "● Artifact(<target>)" then a "└ published · <url>" line from
-- the RESULT (URL pattern-matched out of the result text, not a fixed field).
claude.state.tool_run = nil
feed({ type = "assistant", message = { content = { {
  type = "tool_use", id = "toolu_art1", name = "Artifact",
  input = { file_path = "/tmp/foo/report.md", description = "A report" },
} } } })
H.check("S25 Artifact tool_use renders the '● Artifact(<target>)' header",
  panel_text():find("● Artifact(", 1, true) ~= nil, panel_text())
feed({ type = "user", message = { content = { {
  type = "tool_result", tool_use_id = "toolu_art1",
  content = "Artifact published: https://claude.ai/code/artifact/abc-123",
} } } })
H.check("S25 Artifact result renders the 'published · <url>' line",
  panel_text():find("published · https://claude.ai/code/artifact/abc%-123") ~= nil, panel_text())

-- A `list` result carries MANY URLs → every one renders (not just the first).
claude.state.tool_run = nil
feed({ type = "assistant", message = { content = { {
  type = "tool_use", id = "toolu_art2", name = "Artifact",
  input = { action = "list" },
} } } })
feed({ type = "user", message = { content = { {
  type = "tool_result", tool_use_id = "toolu_art2",
  content = "1. Alpha https://claude.ai/code/artifact/aaa\n2. Beta https://claude.ai/code/artifact/bbb",
} } } })
H.check("S25 Artifact list renders all URLs (first)",
  panel_text():find("https://claude.ai/code/artifact/aaa", 1, true) ~= nil, panel_text())
H.check("S25 Artifact list renders all URLs (second)",
  panel_text():find("https://claude.ai/code/artifact/bbb", 1, true) ~= nil, panel_text())

-- An ERROR result (no URL) falls back to the generic body — nothing swallowed.
claude.state.tool_run = nil
feed({ type = "assistant", message = { content = { {
  type = "tool_use", id = "toolu_art3", name = "Artifact",
  input = { file_path = "/tmp/foo/bad.md" },
} } } })
feed({ type = "user", message = { content = { {
  type = "tool_result", tool_use_id = "toolu_art3", is_error = true,
  content = "Publish failed: CSP violation",
} } } })
H.check("S25 Artifact error result falls back to the generic body",
  panel_text():find("Publish failed", 1, true) ~= nil, panel_text())

-- ── S26: compact-summary string content does not crash dispatch ────────────────
-- /compact (and autocompact) inject a message whose `content` is a plain STRING, not
-- a block array. Every dispatch content-loop assumed an array → "bad argument #1 to
-- 'ipairs' (table expected, got string)" crashed the whole turn (2026-07-13). Feeding
-- both a user- and assistant-shaped string-content message must now be a clean no-op.
claude.state.tool_run = nil
local ok_u = pcall(function()
  feed({ type = "user", message = { content = "Compact summary: prior turns condensed." } })
end)
H.check("S26 string-content user event does not crash dispatch", ok_u, tostring(ok_u))
local ok_a = pcall(function()
  feed({ type = "assistant", message = { content = "A plain string body." } })
end)
H.check("S26 string-content assistant event does not crash dispatch", ok_a, tostring(ok_a))
-- The full captured compact lifecycle (status compacting → done → init → boundary)
-- also dispatches cleanly.
local ok_c = pcall(function()
  feed({ type = "system", subtype = "status", status = "compacting" })
  feed({ type = "system", subtype = "status", status = vim.NIL, compact_result = "success" })
  feed({ type = "system", subtype = "init", model = "claude-opus-4-8" })
  feed({ type = "system", subtype = "compact_boundary", compact_metadata = {
    trigger = "manual", pre_tokens = 30762, post_tokens = 6127,
    cumulative_dropped_tokens = 24635, duration_ms = 17494 } })
end)
H.check("S26 full compact lifecycle dispatches cleanly", ok_c, tostring(ok_c))

-- ── S27: /compact modal → token receipt (F4) ───────────────────────────────────
-- status="compacting" opens the animated modal; compact_boundary replaces it in place
-- with a pre→post/dropped token receipt. No incremental %% exists in the stream.
claude.state.tool_run = nil
feed({ type = "system", subtype = "status", status = "compacting" })
H.check("S27 compacting shows the modal line",
  panel_text():find("Compacting conversation", 1, true) ~= nil, panel_text())
feed({ type = "system", subtype = "compact_boundary", compact_metadata = {
  trigger = "manual", pre_tokens = 40000, post_tokens = 5000,
  cumulative_dropped_tokens = 35000 } })
H.check("S27 boundary replaces the modal with a token receipt",
  panel_text():find("Compacted 40.0K → 5.0K tokens", 1, true) ~= nil, panel_text())
H.check("S27 receipt shows dropped total + trigger",
  panel_text():find("(−35.0K) · manual", 1, true) ~= nil, panel_text())
H.check("S27 animated modal line is gone once the receipt lands",
  count_occurrences(panel_text(), "Compacting conversation…") == 0, panel_text())

-- Autocompact populates the SAME modal (trigger="auto"); dropped is derived when the
-- boundary omits cumulative_dropped_tokens (pre-post).
feed({ type = "system", subtype = "status", status = "compacting" })
feed({ type = "system", subtype = "compact_boundary", compact_metadata = {
  trigger = "auto", pre_tokens = 50000, post_tokens = 8000 } })
H.check("S27 autocompact renders the receipt with derived drop + auto trigger",
  panel_text():find("Compacted 50.0K → 8.0K tokens (−42.0K) · auto", 1, true) ~= nil, panel_text())

-- ── S28: rate-limit block (F5) ─────────────────────────────────────────────────
-- rate_limit_event is per-turn telemetry: status="allowed" renders NOTHING; a real
-- limit (any other status) renders an informational block, de-duped across turns.
claude.state.tool_run = nil
feed({ type = "rate_limit_event", rate_limit_info = {
  status = "allowed", resetsAt = 1783997400, rateLimitType = "five_hour" } })
H.check("S28 allowed status renders no block",
  panel_text():find("Rate limit reached", 1, true) == nil, panel_text())
feed({ type = "rate_limit_event", rate_limit_info = {
  status = "rejected", resetsAt = 1783997400, rateLimitType = "five_hour" } })
H.check("S28 an actual limit renders the block (type shown)",
  panel_text():find("Rate limit reached (five hour)", 1, true) ~= nil, panel_text())
H.check("S28 block lists the reset time + wait option",
  panel_text():find("Resets at", 1, true) ~= nil
    and panel_text():find("Stop and wait for the limit to reset", 1, true) ~= nil, panel_text())
feed({ type = "rate_limit_event", rate_limit_info = {
  status = "rejected", resetsAt = 1783997400, rateLimitType = "five_hour" } })
H.check("S28 the same limit reported again is NOT duplicated",
  count_occurrences(panel_text(), "Rate limit reached") == 1, panel_text())
-- Back under the limit clears the de-dupe latch so a future limit re-shows.
feed({ type = "rate_limit_event", rate_limit_info = { status = "allowed" } })
feed({ type = "rate_limit_event", rate_limit_info = {
  status = "rejected", resetsAt = 1783999999, rateLimitType = "five_hour" } })
H.check("S28 a new limit after recovery re-shows the block",
  count_occurrences(panel_text(), "Rate limit reached") == 2, panel_text())

H.summary("claude_stream")
