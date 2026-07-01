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
-- as frozen. The animated in-body placeholder line carries the "typing" word (a
-- REAL buffer line, so it shows up in nvim_buf_get_lines; the bottom spinner hint
-- is virt_text and does NOT). The spinner bracket omits "typing" while the
-- placeholder owns it, so the word appears exactly once, in the body.
H.check("S0 working compute gap paints the in-body 'typing' placeholder",
  panel_text():find("typing", 1, true) ~= nil, panel_text())

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
H.check("S1 in-body typing placeholder persists while text streams",
  panel_text():find("typing", 1, true) ~= nil, panel_text())
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

-- ── S4: thinking / tool phases still take priority over the typing default ─────

claude.state.think_start = vim.loop.now()
claude.state.think_idx   = 0
H.check("S4 thinking phase overrides the typing default",
  (claude._spinner_label() or ""):find("thinking", 1, true) ~= nil,
  claude._spinner_label())
claude.state.think_start = nil
claude.state.tool_run = { label = "Running: tree -L 1" }
H.check("S4 tool phase overrides the typing default",
  (claude._spinner_label() or ""):find("Running: tree", 1, true) ~= nil,
  claude._spinner_label())
claude.state.tool_run = nil

-- ── S5: in-body "typing" placeholder lifecycle ────────────────────────────────
-- A REAL animated line (unlike the virt_text hint) paints during the compute gap,
-- is REPLACED by the styled block when content lands, and is cleared for good at
-- the turn's `result`. _send paints it synchronously; the assistant/result events
-- are scheduled (on_stdout defers via vim.schedule), so feed() waits for dispatch.
claude.state.think_start = nil
claude.state.tool_run    = nil
claude._send("second question")     -- start_spinner paints the placeholder synchronously
H.check("S5 placeholder painted in body during the compute gap",
  panel_text():find("typing", 1, true) ~= nil, panel_text())

aggregated_text("A styled answer.")
-- The styled block landed; the tick may re-add the placeholder BELOW it for the
-- next dead band (correct), so we only assert the block is present here.
H.check("S5 styled block lands from the aggregated event",
  panel_text():find("A styled answer%.") ~= nil, panel_text())

-- result ends the turn: stop_spinner clears the placeholder and stops the tick, so
-- no "typing" line survives once the model is idle.
feed({ type = "result", result = "ok", total_cost_usd = 0.02 })
H.check("S5 result leaves no placeholder behind",
  panel_text():find("typing", 1, true) == nil, panel_text())
H.check("S5 styled block survives the turn end, single copy",
  count_occurrences(panel_text(), "A styled answer.") == 1, panel_text())

H.summary("claude_stream")
