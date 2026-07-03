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
H.check("S7 long body shows the first K lines",
  panel_text():find("r6", 1, true) ~= nil, panel_text())
H.check("S7 long body hides overflow lines",
  panel_text():find("r7", 1, true) == nil, panel_text())
H.check("S7 long body shows '+3 lines (ctrl+o to expand)'",
  panel_text():find("+3 lines (ctrl+o to expand)", 1, true) ~= nil, panel_text())
H.check("S7 long body stashes the full body on state.tool_results",
  (function()
    local tr = claude.state.tool_results
    local last = tr and tr[#tr]
    return last and #last.body == 9 and last.hidden == 3 and last.aff_mark ~= nil
  end)(), vim.inspect(claude.state.tool_results and claude.state.tool_results[#claude.state.tool_results]))

-- Error body: is_error flagged on the stashed entry (red hl not headless-assertable).
feed({ type = "user", message = { content = { {
  type = "tool_result", tool_use_id = "t3", is_error = true,
  content = "Exit code 1\ncat: nope: No such file or directory",
} } } })
H.check("S7 error body rendered",
  panel_text():find("No such file or directory", 1, true) ~= nil, panel_text())
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

H.summary("claude_stream")
