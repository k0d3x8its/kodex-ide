-- tests/claude_pet_wire_spec.lua
-- Clawd overlay — WIRING spec (spec steps 4-6). The pure state machine is proven
-- headless in claude_pet_spec.lua; THIS spec proves the SEAMS actually call
-- pet.emit end-to-end: feed real stream-json through the panel's dispatch (and
-- drive the init/gate diff + chat seams) and assert pet.state resolves correctly.
-- The renderer is still the no-op stub, so this needs no terminal.
-- Run: nvim --headless -u NONE --cmd "set runtimepath+=." -c "luafile tests/claude_pet_wire_spec.lua"

local H = dofile("tests/helpers.lua")
H.stub_project_root("/tmp")

-- ── Subprocess + module stubs (mirror claude_stream_spec.lua) ─────────────────
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
  watch = function() end, poll = function() end,
  accept_all = function() end, reject_all = function() end,
}
package.loaded["utils.opencode"] = {
  state = { opencode_active = false }, toggle = function() end,
}

local claude = require("utils.claude")
claude.setup({ width_pct = 0.40 })
claude.is_available = function() return true end
local pet = require("utils.claude.pet")

-- Feed one stream-json event through the captured stdout callback.
local function feed(ev)
  captured_stdout_cb(99, { vim.json.encode(ev), "" }, "stdout")
  vim.wait(20)
end
-- Feed an assistant message carrying one content block (tool_use / text).
local function assistant(block)
  feed({ type = "assistant", message = { content = { block } } })
end

-- ── Open the panel + spawn (captures on_stdout, same as the stream spec) ──────
vim.cmd("cd /tmp")
claude.toggle()
vim.wait(30)
claude._send("hello")
vim.wait(30)
H.check("W0 stdout callback captured", captured_stdout_cb ~= nil)
H.check("W0 pet starts asleep", pet.state == "sleep", "state=" .. tostring(pet.state))

-- ── Turn lifecycle seams (render.lua dispatch) ────────────────────────────────

-- W1 thinking — a thinking content_block_start flips the pet to reasoning.
feed({ type = "stream_event",
  event = { type = "content_block_start", index = 0,
            content_block = { type = "thinking" } } })
H.check("W1 thinking seam → thinking", pet.state == "thinking", "state=" .. tostring(pet.state))

-- W2 typing — an aggregated assistant text block flips to generating output.
assistant({ type = "text", text = "hi there" })
H.check("W2 text seam → typing", pet.state == "typing", "state=" .. tostring(pet.state))

-- W3 reading — a Read tool_use classifies to reading.
assistant({ type = "tool_use", id = "t1", name = "Read", input = { file_path = "/tmp/x.lua" } })
H.check("W3 Read seam → reading", pet.state == "reading", "state=" .. tostring(pet.state))

-- W4 debugging — a Bash test-runner command classifies to debugging (a pet-only
-- state the stream never labels; proves the classify heuristic runs at the seam).
assistant({ type = "tool_use", id = "t2", name = "Bash", input = { command = "pytest -q" } })
H.check("W4 Bash pytest seam → debugging", pet.state == "debugging", "state=" .. tostring(pet.state))

-- W5 cleaning — a destructive Bash command classifies to cleaning.
assistant({ type = "tool_use", id = "t3", name = "Bash", input = { command = "rm -rf build/" } })
H.check("W5 Bash rm seam → cleaning", pet.state == "cleaning", "state=" .. tostring(pet.state))

-- W6 subagent — an Agent spawn drives the juggling state. Reset first: cleaning
-- (from W5) outranks subagent in the priority list, so a lingering work-state
-- would mask it (that ordering is intentional and covered by claude_pet_spec).
pet.reset()
assistant({ type = "tool_use", id = "a1", name = "Agent",
            input = { description = "sub", subagent_type = "general-purpose" } })
H.check("W6 Agent spawn seam → subagent", pet.state == "subagent", "state=" .. tostring(pet.state))

-- W7 result success — the turn's result event flashes happy. Reset first so the
-- W6 subagent condition (still active — it clears on the task lifecycle, not here)
-- doesn't outrank happy.
pet.reset()
feed({ type = "result", subtype = "success", is_error = false })
H.check("W7 result success seam → happy", pet.state == "happy", "state=" .. tostring(pet.state))

-- W8 result failure — is_error flips the same seam to error.
feed({ type = "result", subtype = "error_during_execution", is_error = true })
H.check("W8 result error seam → error", pet.state == "error", "state=" .. tostring(pet.state))

-- ── Chat-bar seam (init.lua open_chat_float) ──────────────────────────────────

-- W9 chat_open — opening the reply bar wakes the pet to idle.
pet.reset()
claude._open_chat_float("Reply to Claude", function() end)
vim.wait(20)
H.check("W9 chat bar open seam → idle", pet.state == "idle", "state=" .. tostring(pet.state))

-- ── Diff seams (init.lua on_diff_open + gate.lua resolve) ─────────────────────

-- W10 diff_open — a pending review raises the notification state. on_diff_open
-- emits before it tries to render the (float) card, so this holds headless.
pet.reset()
claude.on_diff_open({ path = "/tmp/x.lua", kind = "modify" })
H.check("W10 on_diff_open seam → diff_wait", pet.state == "diff_wait", "state=" .. tostring(pet.state))

-- W11 diff_resolve — resolving a prewrite gate flashes approved/rejected. Only
-- runs if the public surface exposes on_prewrite_resolve (it is re-exported).
if type(claude.on_prewrite_resolve) == "function" then
  claude.state.job_id   = 99
  claude.state.prewrite = { request_id = "r1", input = {} }
  claude.on_prewrite_resolve(true)
  H.check("W11 prewrite accept seam → diff_approved",
    pet.state == "diff_approved", "state=" .. tostring(pet.state))

  claude.state.prewrite = { request_id = "r2", input = {} }
  claude.on_prewrite_resolve(false)
  H.check("W11 prewrite reject seam → diff_rejected",
    pet.state == "diff_rejected", "state=" .. tostring(pet.state))
else
  H.check("W11 on_prewrite_resolve exposed (diff_resolve seam)", false,
    "claude.on_prewrite_resolve not on public surface")
end

-- W12 diff_close clears diff_wait (Gate-3 HIGH regression). The winbar
-- <leader>ca/cx fallback for a post-write diff bypasses diff_resolve and reaches
-- only on_diff_close; without a clear there, diff_wait (priority #2) would latch
-- for the rest of the session. Open a diff, then close WITHOUT a diff_resolve.
pet.reset()
claude.on_diff_open({ path = "/tmp/x.lua", kind = "modify" })
H.check("W12 diff open → diff_wait", pet.state == "diff_wait", "state=" .. tostring(pet.state))
claude.on_diff_close()
H.check("W12 on_diff_close clears diff_wait (not latched)",
  pet.state ~= "diff_wait", "state=" .. tostring(pet.state))

-- W13 result clears a stale subagent (Gate-3 MED regression). A dropped final
-- task_notification would leave the pet in `subagent`; the result event must
-- clear it so a successful turn surfaces happy, not a phantom juggling pet.
pet.reset()
assistant({ type = "tool_use", id = "a2", name = "Agent",
            input = { description = "sub2", subagent_type = "general-purpose" } })
H.check("W13 subagent active pre-result", pet.state == "subagent", "state=" .. tostring(pet.state))
feed({ type = "result", subtype = "success", is_error = false })
H.check("W13 result clears stale subagent → happy",
  pet.state == "happy", "state=" .. tostring(pet.state))

H.summary("claude_pet_wire")
