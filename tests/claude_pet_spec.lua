-- tests/claude_pet_spec.lua
-- Drives the PURE Clawd pet state machine (lua/utils/claude/pet.lua): the
-- priority resolver, idle progression on an injected clock, tool→state
-- classification, event transitions, and the render-on-change contract. No
-- terminal / kitty graphics needed — the whole point of the pure core is that
-- it runs headless behind a stub renderer.
-- Run: nvim --headless -u NONE --cmd "set runtimepath+=." -c "luafile tests/claude_pet_spec.lua"

local H = dofile("tests/helpers.lua")

local pet = require("utils.claude.pet")

-- Record every render() call so we can assert both the resolved state and that
-- the renderer fires ONLY on a real change.
local renders = {}
pet.render = function(new, prev) table.insert(renders, { new = new, prev = prev }) end

local function reset()
  pet.reset()
  renders = {}
end

-- ── Classification (P-CLS) ───────────────────────────────────────────────────
H.check("P-CLS1 Read → reading", pet.classify("Read", {}) == "reading")
H.check("P-CLS2 NotebookRead → reading", pet.classify("NotebookRead", {}) == "reading")
H.check("P-CLS3 Grep → reading", pet.classify("Grep", {}) == "reading")
H.check("P-CLS4 Bash rm → cleaning",
  pet.classify("Bash", { command = "rm -rf build/" }) == "cleaning")
H.check("P-CLS5 Bash mv → cleaning",
  pet.classify("Bash", { command = "mv old.lua new.lua" }) == "cleaning")
H.check("P-CLS6 Bash pytest → debugging",
  pet.classify("Bash", { command = "pytest tests/ -x" }) == "debugging")
H.check("P-CLS7 Bash make test → debugging",
  pet.classify("Bash", { command = "make test" }) == "debugging")
H.check("P-CLS8 debugging beats nothing; test+rm resolves to debugging first",
  pet.classify("Bash", { command = "cargo test && rm target/x" }) == "debugging")
H.check("P-CLS9 plain Bash → reading (generic)",
  pet.classify("Bash", { command = "ls -la" }) == "reading")
H.check("P-CLS10 Edit → building", pet.classify("Edit", {}) == "building")
H.check("P-CLS11 Write → building", pet.classify("Write", {}) == "building")
H.check("P-CLS12 MultiEdit → building", pet.classify("MultiEdit", {}) == "building")
H.check("P-CLS13 NotebookEdit → building", pet.classify("NotebookEdit", {}) == "building")
H.check("P-CLS14 unknown tool → nil (keep prior state)", pet.classify("Task", {}) == nil)

-- ── Priority resolver (P-PRI) ────────────────────────────────────────────────
-- Stack several simultaneous conditions; the highest priority must win.
reset()
pet.cond.work     = "typing"
pet.cond.subagent = true
pet.cond.diff     = "wait"
pet.cond.flash    = "error"
H.check("P-PRI1 error beats everything", pet.resolve() == "error")

reset()
pet.cond.work = "typing"
pet.cond.diff = "wait"
H.check("P-PRI2 diff_wait beats typing", pet.resolve() == "diff_wait")

reset()
pet.cond.work     = "reading"
pet.cond.subagent = true
H.check("P-PRI3 reading beats subagent (rev-3 order)", pet.resolve() == "reading")

reset()
pet.cond.work     = "typing"
pet.cond.subagent = true
H.check("P-PRI4 subagent beats typing", pet.resolve() == "subagent")

reset()
pet.cond.work = "debugging"
H.check("P-PRI5 debugging over cleaning/reading", pet.resolve() == "debugging")

reset()
H.check("P-PRI6 nothing active → sleep floor", pet.resolve() == "sleep")

-- ── Event lifecycle (P-EVT) ──────────────────────────────────────────────────
reset()
H.check("P-EVT1 chat_open wakes to idle", pet.emit("chat_open", { now = 0 }) == "idle")
H.check("P-EVT2 chat_open fired one render", #renders == 1 and renders[1].new == "idle")

-- Submit must NOT sleep — it hands off to the work lifecycle (stops idling).
pet.emit("chat_submit")
H.check("P-EVT3 submit does not sleep", pet.state ~= "sleep")
H.check("P-EVT3b submit stops idle progression", pet.idle_from == nil)

H.check("P-EVT4 thinking", pet.emit("thinking") == "thinking")
H.check("P-EVT5 typing", pet.emit("typing") == "typing")
H.check("P-EVT6 tool_use Read → reading",
  pet.emit("tool_use", { name = "Read", input = {} }) == "reading")
H.check("P-EVT7 tool_use Bash rm → cleaning",
  pet.emit("tool_use", { name = "Bash", input = { command = "rm x" } }) == "cleaning")
H.check("P-EVT8 tool_use Edit → building (write in progress)",
  pet.emit("tool_use", { name = "Edit", input = {} }) == "building")
H.check("P-EVT8b tool_use unknown keeps prior state (nil classify)",
  pet.emit("tool_use", { name = "SomeNewTool", input = {} }) == "building")

-- Result success → happy, then idle progression owns the clock.
H.check("P-EVT9 result ok → happy", pet.emit("result", { ok = true, now = 100 }) == "happy")
H.check("P-EVT10 result failure → error",
  pet.emit("result", { ok = false }) == "error")

-- ── Interrupt (P-INT) — aborted turn flashes error (user-chosen sprite) ────────
reset()
pet.emit("tool_use", { name = "Read", input = {} })   -- pet now "reading"
H.check("P-INT1 interrupt drops work → error sprite",
  pet.emit("interrupt", { now = 0 }) == "error")
H.check("P-INT1b interrupt cleared c.work", pet.cond.work == nil)
H.check("P-INT1c interrupt set error flash", pet.cond.flash == "error")
-- The CLI's trailing abort result (non-ok) lands on the SAME error flash — no flip.
H.check("P-INT1d trailing abort result stays error",
  pet.emit("result", { ok = false }) == "error")

-- ── Diff lifecycle (P-DIFF) ──────────────────────────────────────────────────
reset()
H.check("P-DIFF1 diff_open → diff_wait", pet.emit("diff_open") == "diff_wait")
H.check("P-DIFF2 accept → diff_approved",
  pet.emit("diff_resolve", { accepted = true }) == "diff_approved")
pet.emit("diff_open")
H.check("P-DIFF3 reject → diff_rejected",
  pet.emit("diff_resolve", { accepted = false }) == "diff_rejected")

-- ── Subagent (P-SUB) ─────────────────────────────────────────────────────────
reset()
pet.emit("typing")
H.check("P-SUB1 subagent active surfaces over typing",
  pet.emit("subagent", { active = true }) == "subagent")
H.check("P-SUB2 subagent clear falls back to typing",
  pet.emit("subagent", { active = false }) == "typing")

-- ── Idle progression on injected clock (P-IDLE) ──────────────────────────────
reset()
pet.emit("result", { ok = true, now = 0 })   -- happy + idle clock starts at 0
H.check("P-IDLE1 t=0 happy", pet.state == "happy")
-- Schedule: idle 0–15s, groove 15–45s (30s), idle 45–60s, sleep 60s+.
H.check("P-IDLE2 t=10 → idle (happy dropped)", pet.advance(10) == "idle")
H.check("P-IDLE3 t=20 → headphones_groove", pet.advance(20) == "headphones_groove")
H.check("P-IDLE4 t=50 → idle (post-groove)", pet.advance(50) == "idle")
H.check("P-IDLE5 t=65 → sleep", pet.advance(65) == "sleep")

-- User action mid-progression resets the clock back to idle.
pet.emit("user_action", { now = 200 })
H.check("P-IDLE6 user_action resets to idle", pet.state == "idle")
H.check("P-IDLE7 clock reset — t=210 still idle (only +10)", pet.advance(210) == "idle")
H.check("P-IDLE8 t=220 groove again (20 past reset)", pet.advance(220) == "headphones_groove")

-- advance() is a no-op when not idling (mid-turn).
reset()
pet.emit("typing")
local before = pet.state
H.check("P-IDLE9 advance no-op mid-turn", pet.advance(999) == before)

-- ── Permission / question modal → building | notification (P-PERM) ────────────
-- Edit/Write permission → building; any other modal → notification; both outrank
-- the underlying work state and clear back to it on resolve.
reset()
pet.emit("tool_use", { name = "Read", input = { file_path = "/x" } })
H.check("P-PERM0 reading before modal", pet.state == "reading")
pet.emit("permission", { active = true, build = true })
H.check("P-PERM1 edit perm → building", pet.state == "building")
pet.emit("permission", { active = false })
H.check("P-PERM2 resolve → reading resurfaces", pet.state == "reading")
pet.emit("permission", { active = true, build = false })
H.check("P-PERM3 other modal → notification", pet.state == "notification")
pet.emit("permission", { active = false })
H.check("P-PERM4 resolve → reading again", pet.state == "reading")

-- ── Render fires only on change (P-RND) ──────────────────────────────────────
reset()
renders = {}
pet.emit("typing")
pet.emit("typing")           -- same state, must NOT re-render
pet.emit("thinking")
H.check("P-RND1 no render on unchanged state", #renders == 2)
H.check("P-RND2 render carries prev",
  renders[2].prev == "typing" and renders[2].new == "thinking")

H.summary("claude_pet_spec")
