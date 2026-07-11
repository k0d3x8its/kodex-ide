-- lua/utils/claude/pet.lua
-- Pure Clawd pet STATE MACHINE — the testable core of the overlay (spec:
-- docs/clawd-overlay-spec.md). Three jobs, all renderer-agnostic:
--   1. priority resolver   — many conditions can be true at once; pick the
--                            highest-priority one (the spec's 14-level list).
--   2. idle progression    — after Claude finishes, walk idle → groove → idle →
--                            sleep on a clock, reset on any user action.
--   3. tool classification — map a tool_use to reading / cleaning / debugging,
--                            adding the two states the stream never labels.
--
-- WHY a pure core: the renderer (image.nvim + timer frame-swap, LOCKED in the
-- spec) is the untestable part — it needs kitty graphics + a real terminal. So
-- ALL the logic lives here behind a stub `render(state)` callback and an
-- INJECTABLE clock (`emit`/`advance` are driven by the caller, never by wall
-- time), which lets the whole machine run under `nvim --headless`. The real
-- integration wires `render` to the frame-swapper and pumps `advance` from a
-- vim.loop timer; nothing about the logic below changes.
--
-- Run the spec: nvim --headless -u NONE --cmd "set runtimepath+=." \
--   -c "luafile tests/claude_pet_spec.lua"

local M = {}

-- ── Priority model (spec §Priority Model) ────────────────────────────────────
-- Highest first. resolve() returns the first state whose condition is active.
-- Kept as an explicit ordered list (not scattered if/elseif) so it reads 1:1
-- against the spec table and a re-order is a one-line edit. `subagent` sits at 8
-- per rev-3; the spec notes it MAY be promoted above reading/cleaning when a
-- subagent is the dominant activity — left as a deliberate config knob below.
local PRIORITY = {
  "error",
  "building",        -- an Edit/Write permission is up → building sprite
  "notification",    -- any other permission/question modal is up → notification sprite
                     -- (both outrank reading etc. so the modal-wait state always wins)
  "diff_wait",
  "diff_rejected",
  "diff_approved",
  "debugging",
  "cleaning",
  "reading",
  "subagent",
  "thinking",
  "typing",
  "happy",
  "headphones_groove",
  "idle",
  "sleep",
}

-- ── Idle progression schedule (spec §Idle Progression) ───────────────────────
-- Seconds-since-idle-start → phase. Ordered high→low so the first threshold met
-- when scanning wins. Begins ONLY after Claude finishes answering (or the chat
-- bar opens); any user action resets the clock to 0.
local IDLE_STAGES = {
  { at = 60, phase = "sleep" },              -- after the full cycle: sleep until active
  { at = 45, phase = "idle" },               -- 15s idle again (45→60)
  { at = 15, phase = "headphones_groove" },  -- 30s of groove (15→45)
  { at = 0,  phase = "idle" },               -- 15s idle first (0→15)
}

-- ── Tool → state classification (spec §Heuristics) ───────────────────────────
-- render.lua already labels reading/running/searching for the PANEL; the pet
-- needs the two states the stream never marks: `cleaning` (destructive fs op)
-- and `debugging` (tests / logs / traces). Everything else falls to the generic
-- `reading` per the spec's "when ambiguous, don't guess" rule.
--
-- Plain-substring token lists (Lua patterns have no alternation, and these are
-- command words, not regexes). Matched against a lowercased command string.
local CLEANING_TOKENS = {
  "rm ", "rm -", "rmdir", "mv ", "unlink", "rename", "prune", "git clean",
}
local DEBUGGING_TOKENS = {
  "pytest", "jest", "npm test", "npm run test", "yarn test", "make test",
  "cargo test", "go test", "busted", "rspec", "phpunit", "gradle test",
  "tail ", "stacktrace", "traceback", "grep -", " grep ", "journalctl",
}

-- Return the pet work-state for a tool_use, or nil if the tool is not a
-- work-state driver (Edit/Write/etc. — no dedicated sprite, caller leaves the
-- current state). `name` is the Claude tool name, `input` its input table.
local function classify(name, input)
  input = input or {}
  if name == "Read" or name == "NotebookRead" then
    return "reading"
  end
  if name == "Grep" or name == "Glob" or name == "WebSearch" or name == "WebFetch" then
    return "reading"
  end
  if name == "Bash" then
    local cmd = tostring(input.command or ""):lower()
    for _, tok in ipairs(DEBUGGING_TOKENS) do
      if cmd:find(tok, 1, true) then return "debugging" end
    end
    for _, tok in ipairs(CLEANING_TOKENS) do
      if cmd:find(tok, 1, true) then return "cleaning" end
    end
    -- Non-destructive, non-test shell command: generic activity.
    return "reading"
  end
  if name == "Edit" or name == "Write"
      or name == "MultiEdit" or name == "NotebookEdit" then
    -- Clawd constructs code while the file is actually being written — the same
    -- sprite the Edit/Write permission card and the pending diff review use, so
    -- the whole edit lifecycle (perm → write → diff wait) reads as one activity.
    return "building"
  end
  -- Unknown tools: no dedicated state. Returning nil lets the machine keep
  -- whatever it was showing (typically `typing`) rather than flip to a
  -- misleading sprite.
  return nil
end
M.classify = classify  -- exposed for the spec

-- ── Machine state ────────────────────────────────────────────────────────────
-- Conditions the resolver reads. Grouped by lifecycle so the resolver stays a
-- flat scan. `flash` holds one-shot RESULT states (error/happy/diff outcome)
-- that persist until the next turn or user action supersedes them.
local function fresh_conditions()
  return {
    work       = nil,   -- streaming activity: thinking|typing|reading|cleaning|debugging
    subagent   = false, -- a subagent task is running (state.subagents non-empty)
    diff       = nil,   -- "wait" while a diff/prewrite review is pending
    flash      = nil,   -- transient: error|happy|diff_approved|diff_rejected
    idle_phase = nil,   -- idle|headphones_groove|sleep, or nil while working
    permission = nil,   -- "build" (Edit/Write perm) | "notify" (other modal) | nil
  }
end

M.cond      = fresh_conditions()
M.idle_from = nil       -- clock value when idle progression started; nil = not idling
M.state     = "sleep"   -- last resolved state (what the renderer is showing)

-- Injected seam. `render(new_state, prev_state)` fires only on a real change.
-- Default is a no-op recorder so requiring the module never needs a terminal.
M.render = function(_, _) end

-- Default monotonic clock (seconds). The idle progression needs a `now` on the
-- events that (re)start its timer (chat_open / result-success / user_action) and
-- on advance(); the wiring seams don't thread one, so emit() falls back to this.
-- Uses the SAME source the real advance-pump timer will use (vim.loop.now() ms →
-- s) so elapsed math is consistent. Tests inject an explicit `now` and never hit
-- this. Guarded for the headless spec runner where vim.loop may be absent.
M.now = function()
  if vim and vim.loop and vim.loop.now then return vim.loop.now() / 1000 end
  return os.time()
end

-- ── Resolver ─────────────────────────────────────────────────────────────────
-- Map a state NAME to whether its condition is currently active. Encodes the
-- priority list's semantics; PRIORITY just fixes the scan order.
local function active(name, c)
  if name == "error"          then return c.flash == "error" end
  -- building fires for BOTH the Edit/Write permission card AND the write itself
  -- (classify maps Edit/Write/MultiEdit/NotebookEdit to work="building"): the
  -- sprite is the same, so the higher (permission) slot covers both without a
  -- second PRIORITY entry.
  if name == "building"       then return c.permission == "build" or c.work == "building" end
  if name == "notification"   then return c.permission == "notify" end
  if name == "diff_wait"      then return c.diff == "wait" end
  if name == "diff_rejected"  then return c.flash == "diff_rejected" end
  if name == "diff_approved"  then return c.flash == "diff_approved" end
  if name == "debugging"      then return c.work == "debugging" end
  if name == "cleaning"       then return c.work == "cleaning" end
  if name == "reading"        then return c.work == "reading" end
  if name == "subagent"       then return c.subagent end
  if name == "thinking"       then return c.work == "thinking" end
  if name == "typing"         then return c.work == "typing" end
  if name == "happy"          then return c.flash == "happy" end
  if name == "headphones_groove" then return c.idle_phase == "headphones_groove" end
  if name == "idle"           then return c.idle_phase == "idle" end
  if name == "sleep"          then return true end  -- floor: always active
  return false
end

-- Resolve the highest-priority active state.
local function resolve(c)
  for _, name in ipairs(PRIORITY) do
    if active(name, c) then return name end
  end
  return "sleep"
end
M.resolve = function() return resolve(M.cond) end

-- Recompute and fire the renderer if the resolved state changed.
local function refresh()
  local next_state = resolve(M.cond)
  if next_state ~= M.state then
    local prev = M.state
    M.state = next_state
    -- pcall: emit runs on the hot stream-json dispatch path (which also renders
    -- the transcript). The renderer is a no-op stub today, but once the image.nvim
    -- renderer lands a throw here must NOT propagate up and break dispatch.
    pcall(M.render, next_state, prev)
  end
  return M.state
end

-- Enter the idle lifecycle: clear streaming work, start the progression clock.
-- `now` is the caller's clock value (seconds). Called on turn-success and on
-- chat-open.
local function enter_idle(now)
  M.cond.work       = nil
  M.cond.idle_phase = "idle"
  M.idle_from       = now or 0
end

-- ── Event API (spec §Event Sources) ──────────────────────────────────────────
-- `emit(event, data)` is the single injected callback the wiring seams call
-- (`pet.on(...)` in the spec). `data` carries the payload for tool_use/result/
-- diff/subagent events. Every branch ends by refreshing the resolved state.
--
-- data fields used:
--   tool_use : { name = <tool>, input = <table> }
--   result   : { ok = <bool> }
--   diff     : { accepted = <bool> }   (only for diff_resolve)
--   subagent : { active = <bool> }
--   now      : caller clock (seconds) for events that (re)start the idle clock
function M.emit(event, data)
  data = data or {}
  local c = M.cond
  -- Idle-restart events need a clock consistent with advance(); tests inject one
  -- via data.now, the wiring seams don't → fall back to the default clock.
  local now = data.now or M.now()

  if event == "chat_open" then
    -- Bar opened = user is here. Clear stale results, wake to idle, restart the
    -- progression clock (a user action). Keep awake while the bar is visible.
    c.flash = nil
    enter_idle(now)

  elseif event == "chat_submit" then
    -- User sent a prompt: Claude is about to work. The pet must NOT sleep in the
    -- gap before the first thinking/typing event (spec §Critical Timing). Hold
    -- `idle` (awake) but STOP the progression clock (idle_from = nil) so it can
    -- never tick down to sleep on its own — the turn lifecycle drives it from
    -- here. work events clear idle_phase when they arrive.
    c.flash      = nil
    c.idle_phase = "idle"
    M.idle_from  = nil

  elseif event == "thinking" then
    c.idle_phase, M.idle_from = nil, nil
    c.flash = nil
    c.work  = "thinking"

  elseif event == "typing" then
    c.idle_phase, M.idle_from = nil, nil
    c.flash = nil
    c.work  = "typing"

  elseif event == "tool_use" then
    c.idle_phase, M.idle_from = nil, nil
    c.flash = nil
    local st = classify(data.name, data.input)
    if st then c.work = st end  -- nil (Edit/Write/…) keeps the current state

  elseif event == "permission" then
    -- A permission/question modal is up (blocks the turn, waits on the user). An
    -- Edit/Write file request → the building sprite (Clawd constructing code); any
    -- other permission or a question modal → the notification sprite. Cleared when
    -- the last modal resolves. Does NOT touch idle/work state — those resurface
    -- underneath once the modal clears (e.g. reading → building → reading).
    if data.active then
      c.permission = data.build and "build" or "notify"
    else
      c.permission = nil
    end

  elseif event == "subagent" then
    c.subagent = data.active and true or false

  elseif event == "diff_open" then
    c.idle_phase, M.idle_from = nil, nil
    c.diff = "wait"

  elseif event == "diff_resolve" then
    c.diff  = nil
    c.flash = data.accepted and "diff_approved" or "diff_rejected"

  elseif event == "diff_close" then
    -- Safety-net clear. on_diff_close is the single choke point EVERY diff resolve
    -- path funnels through — the card, the prewrite gate, AND the winbar
    -- <leader>ca/cx fallback that bypasses diff_resolve. Without this, a winbar-
    -- resolved post-write diff would latch diff_wait forever (it's priority #2, so
    -- it masks every later state). Deliberately sets NO flash: the resolve paths
    -- that know accept vs reject already set diff_approved/rejected before this
    -- fires, so clearing c.diff here leaves that flash intact.
    c.diff = nil

  elseif event == "result" then
    c.work = nil
    -- Turn end ⇒ no subagent is still juggling. Clear it defensively so a dropped
    -- final task_notification (which would leave state.subagents marked "running")
    -- can't strand the pet in `subagent` — it outranks happy/idle in the resolver.
    c.subagent = false
    if data.ok then
      -- Turn succeeded: flash happy, then hand off to the idle progression.
      c.flash = "happy"
      enter_idle(now)
    else
      c.flash      = "error"
      c.idle_phase = nil
      M.idle_from  = nil
    end

  elseif event == "user_action" then
    -- Any interaction that resets the idle progression (panel focus, keymap,
    -- diff interaction). Only meaningful while idling; ignored mid-turn.
    if M.idle_from ~= nil then enter_idle(now) end

  elseif event == "sleep" or event == "reset" then
    -- Session ended / panel closed: hard floor.
    M.cond      = fresh_conditions()
    M.idle_from = nil
  end

  return refresh()
end

-- ── Idle clock pump (spec §5 Idle timers) ────────────────────────────────────
-- The real integration calls this from a vim.loop timer with the current clock;
-- the spec calls it directly to fast-forward. Advances the idle phase per the
-- schedule when the progression is running, then refreshes.
function M.advance(now)
  if M.idle_from == nil then return M.state end
  local elapsed = (now or 0) - M.idle_from
  for _, stage in ipairs(IDLE_STAGES) do
    if elapsed >= stage.at then
      M.cond.idle_phase = stage.phase
      -- happy is a one-shot; once the idle clock is ticking, drop it so idle/
      -- groove/sleep can surface.
      if M.cond.flash == "happy" then M.cond.flash = nil end
      break
    end
  end
  return refresh()
end

-- Test/integration reset to a known floor.
function M.reset()
  M.cond      = fresh_conditions()
  M.idle_from = nil
  M.state     = "sleep"
end

return M
