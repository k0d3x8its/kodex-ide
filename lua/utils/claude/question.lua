-- lua/utils/claude/question.lua
--
-- The AskUserQuestion card: a vertical multi-question selector float that arrives
-- on the same can_use_tool gate as a permission but is NOT an allow/reject decision
-- (it carries up to 4 questions, each with its own option list, and the answer rides
-- back in updatedInput.answers). Extracted from the former monolithic claude.lua
-- (Goal 15.4) to relieve init's main-chunk 200-local ceiling.
--
-- Dependencies: core.state + core buffer helpers, widgets.float_bottom_row, and ten
-- init-owned float/pad/spinner/permission helpers injected via Question.wire{} (they
-- couple to init's chat-bar/float/permission machinery; injection avoids a require
-- cycle and lets 15.5 re-home the float+permission helpers with a one-line change
-- here). show_question_card is called by init's dispatcher; the rest are exposed
-- only so init can re-export the `mod._question*` test hooks.

local Question = {}

local require_prefix = "utils.claude."
local core = require(require_prefix .. "core")
local widgets = require(require_prefix .. "widgets")

local state = core.state
local buf_append  = core.buf_append
local hl_lines    = core.hl_lines

-- Init-owned helpers, injected by Question.wire{} at load time (see init.lua).
-- Declared as forward locals so the card functions below close over them.
local send_permission_response
local panel_float_geom
local harden_float_scroll
local attach_panel_float_resize
local set_bottom_pad
local clear_bottom_pad
local start_spinner
local stop_spinner
local clear_hint
local prompt_input
local set_waiting_hint

--- Inject init's float/pad/spinner/permission helpers. Called once from init after
--- they are defined.
function Question.wire(hooks)
  send_permission_response  = hooks.send_permission_response
  panel_float_geom          = hooks.panel_float_geom
  harden_float_scroll       = hooks.harden_float_scroll
  attach_panel_float_resize = hooks.attach_panel_float_resize
  set_bottom_pad            = hooks.set_bottom_pad
  clear_bottom_pad          = hooks.clear_bottom_pad
  start_spinner             = hooks.start_spinner
  stop_spinner              = hooks.stop_spinner
  clear_hint                = hooks.clear_hint
  prompt_input              = hooks.prompt_input
  set_waiting_hint          = hooks.set_waiting_hint
end

-- ─── Question card (AskUserQuestion) ──────────────────────────────────────────
-- Claude's AskUserQuestion tool arrives on the SAME can_use_tool gate as a
-- permission (no new flag — see .work/FINDINGS.md § Q-ASK), but is NOT an
-- allow/reject decision: it carries up to 4 questions, each with its own option
-- list, and the answer rides back in updatedInput.answers (a map keyed by each
-- question's TEXT, value = chosen label, or an array of labels for multiSelect).
--
-- The card is a VERTICAL selector over the N questions in one float. Unlike a
-- step-through wizard it lets you move FREELY between questions (Tab/⇥ + ←/→) WITHOUT
-- answering first — each question keeps its own highlight + recorded pick, and the
-- card only submits (one control_response with the full answers map) once EVERY
-- question has a pick. Per question the option list is the model's options PLUS two
-- synthetic affordances mirroring the Claude Code TUI: "Type something" (free-text
-- answer) and "Chat about this" (bail → dismiss → reopen the chat bar). Keys:
--   ↑/↓ j/k  move highlight within the question
--   ⇥ / →    next question · ⇤ / ← prev question (no answer required)
--   <Space>  toggle a multiSelect option
--   <CR>     select the highlighted option (records pick; advances to the next
--            UNanswered question, or submits when all are answered). On the
--            "Type something" row it opens an input; "Chat about this" denies with
--            feedback so the model opens a clarification dialogue.
--   <Esc>/q  cancel (allow with NO answers → the CLI emits "Question dismissed").
-- Reuses the permission card's geometry + chat-bar dismiss/reopen plumbing.

local Q_CUSTOM = "Type something"
local Q_CHAT   = "Chat about this"

-- The display option list for a question: model options first, then the two
-- synthetic affordances. Each entry: { kind = "model"|"custom"|"chat",
-- index (model options only), label, desc }.
local function question_display_options(question)
  local d = {}
  for i, opt in ipairs(question.options or {}) do
    d[#d + 1] = { kind = "model", index = i, label = opt.label or "", desc = opt.description or "" }
  end
  d[#d + 1] = { kind = "custom", label = Q_CUSTOM, desc = "Write a custom answer" }
  d[#d + 1] = { kind = "chat",   label = Q_CHAT,   desc = "Skip these and discuss in chat" }
  return d
end

-- Highlighted display-option index for the current question (persisted per
-- question so navigating away + back keeps the cursor where you left it).
local function q_choice(q) return q.choice[q.qi] or 1 end

-- Rebuild the card buffer for the current question (q.qi) in place: question text,
-- the vertical option list (❯ marks the highlighted option; single-select shows a
-- ● on the recorded pick, multiSelect a [x]/[ ] checkbox; the recorded custom text
-- shows inline), a dimmed description under each option, and a nav hint. Recomputes
-- the float height (wrapped rows) and repaints highlights. Called on every state
-- change (move/toggle/nav/pick).
local function render_question_card()
  local q = state.qask
  if not (q and q.buf and vim.api.nvim_buf_is_valid(q.buf)
          and q.win and vim.api.nvim_win_is_valid(q.win)) then return end
  local question = q.questions[q.qi] or {}
  local dopts    = question_display_options(question)
  local ci       = q_choice(q)
  local sel      = q.sel[q.qi] or {}
  local pick     = q.picks[q.qi]
  state.qask_ns  = state.qask_ns or vim.api.nvim_create_namespace("ClaudeQaskRow")

  local lines, hl = {}, {}
  lines[#lines + 1] = "  " .. (question.question or "")
  hl[#hl + 1] = { #lines - 1, "ClaudeProse" }
  lines[#lines + 1] = ""                                   -- spacer

  for i, d in ipairs(dopts) do
    local marker = (i == ci) and "❯ " or "  "
    local mark   = "  "
    if d.kind == "model" and question.multiSelect then
      mark = sel[d.index] and "[x] " or "[ ] "
    elseif d.kind == "model" then
      mark = (pick and pick.kind == "option" and pick.index == d.index) and "● " or "  "
    end
    local label = d.label
    if d.kind == "custom" and pick and pick.kind == "custom" then
      label = label .. ": " .. pick.text
    end
    lines[#lines + 1] = "  " .. marker .. mark .. label
    -- Highlighted row pops burnt-orange; model options read prose-orange; the two
    -- synthetic affordances (Type something / Chat about this) get ClaudeLabel
    -- purple so they're visibly distinct from the gray (ClaudeDim) descriptions
    -- they used to share a colour with.
    local grp = (i == ci) and "ClaudeQuestion"
      or ((d.kind == "model") and "ClaudeProse" or "ClaudeLabel")
    hl[#hl + 1] = { #lines - 1, grp }
    if d.desc ~= "" then
      lines[#lines + 1] = "        " .. d.desc
      hl[#hl + 1] = { #lines - 1, "ClaudeDim" }
    end
  end

  lines[#lines + 1] = ""                                   -- spacer
  local nav = (#q.questions > 1) and " · ⇥ question" or ""
  lines[#lines + 1] = question.multiSelect
    and ("  ↑/↓ move · space toggle" .. nav .. " · ⏎ select · esc cancel")
    or  ("  ↑/↓ move" .. nav .. " · ⏎ select · esc cancel")
  hl[#hl + 1] = { #lines - 1, "ClaudeDim" }

  -- Geometry: full panel-column width (shared helper — same anchoring the
  -- permission/chat floats use). Height tracks wrapped rows so a question that
  -- grows/shrinks the option list never clips the hint. col/width are repositioned
  -- by the resize handler; here we only need the width for the wrap math.
  local _, float_w = panel_float_geom()
  local disp_rows = 0
  for _, l in ipairs(lines) do
    disp_rows = disp_rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(l) / float_w))
  end
  local float_h = math.min(disp_rows, math.max(vim.o.lines - 4, 1))

  vim.bo[q.buf].modifiable = true
  vim.api.nvim_buf_set_lines(q.buf, 0, -1, false, lines)
  vim.bo[q.buf].modifiable = false

  -- SW anchor keeps the bottom edge pinned; only the top moves as height changes.
  pcall(vim.api.nvim_win_set_height, q.win, float_h)
  -- Reserve the card's footprint as bottom padding so existing Claude output is
  -- pushed ABOVE the card instead of being covered by it (same contract the chat
  -- float uses). float_h interior + 2 rounded-border rows + 1 blank separator.
  -- Re-set on every render so the pad tracks the card growing/shrinking as the
  -- user steps between questions with different option counts.
  set_bottom_pad(float_h + 3)
  local title = (#q.questions > 1)
    and (" ❓ Question " .. q.qi .. " of " .. #q.questions .. " ")
    or  " ❓ Question "
  pcall(vim.api.nvim_win_set_config, q.win, { title = title, title_pos = "left" })

  vim.api.nvim_buf_clear_namespace(q.buf, state.qask_ns, 0, -1)
  for _, h in ipairs(hl) do
    vim.api.nvim_buf_add_highlight(q.buf, state.qask_ns, h[2], h[1], 0, -1)
  end
end

-- Move the highlighted display option for the current question (wraps).
local function move_question_choice(delta)
  local q = state.qask
  if not q then return end
  local n = #question_display_options(q.questions[q.qi])
  if n == 0 then return end
  q.choice[q.qi] = (q_choice(q) - 1 + delta) % n + 1
  render_question_card()
end
Question.move_question_choice = move_question_choice

-- Jump to the next/prev question WITHOUT requiring an answer (clamped at the ends).
local function goto_question(delta)
  local q = state.qask
  if not q then return end
  local n = #q.questions
  q.qi = math.min(math.max(q.qi + delta, 1), n)
  render_question_card()
end
local function next_question() goto_question(1) end
local function prev_question() goto_question(-1) end
Question.next_question = next_question
Question.prev_question = prev_question

-- Toggle the highlighted MODEL option in a multiSelect question's selection set.
-- (No-op on the synthetic Type/Chat rows, or on single-select questions.)
local function toggle_question_choice()
  local q = state.qask
  if not (q and q.questions[q.qi].multiSelect) then return end
  local d = question_display_options(q.questions[q.qi])[q_choice(q)]
  if not (d and d.kind == "model") then return end
  q.sel[q.qi] = q.sel[q.qi] or {}
  q.sel[q.qi][d.index] = not q.sel[q.qi][d.index] or nil
  render_question_card()
end
Question.toggle_question_choice = toggle_question_choice

-- Tear the card down (the answer/cancel response is sent by the caller first),
-- drop a one-line transcript receipt, resume the spinner if the turn is still in
-- flight, and reopen any chat bar we dismissed to show the card.
local function close_question_card(receipt, receipt_hl)
  local q = state.qask
  if not q then return end
  state.qask = nil                                   -- before close → WinClosed no-ops
  if q.resize_close then pcall(q.resize_close) end   -- drop the resize-track augroup
  if q.win and vim.api.nvim_win_is_valid(q.win) then
    pcall(vim.api.nvim_win_close, q.win, true)
  end
  -- Drop the footprint pad the card reserved. If a dismissed chat bar is about to
  -- reopen (qask_reopen_bar) it re-sets its own pad on open, so this clear is safe.
  clear_bottom_pad()
  if receipt and state.panel_buf and vim.api.nvim_buf_is_valid(state.panel_buf) then
    local recl = vim.api.nvim_buf_line_count(state.panel_buf)
    buf_append({ receipt })
    hl_lines(recl, recl, receipt_hl or "ClaudeQuestion")
  end
  core.resume_turn()   -- fold the answer wait out of the turn timer (mirrors the tick)
  -- Blank line so the resumed spinner gets its own row, not the receipt's EOL
  -- (same reason as resolve_permission — set_hint anchors to the last line).
  -- Re-baseline the thinking timer past the user's answer time.
  if state.working then
    state.activity_t0 = vim.loop.now()
    buf_append({ "" }); start_spinner()
  else clear_hint() end
  if state.qask_reopen_bar then
    state.qask_reopen_bar = false
    vim.schedule(function() prompt_input() end)
  end
end

-- A question counts as answered once it has a recorded pick (single-select option
-- or custom text), or — for multiSelect — once the user has confirmed it with <CR>
-- (picks[i] = { kind = "multi" }; the actual labels live in sel[i]).
local function question_answered(q, i)
  return q.picks[i] ~= nil
end

-- The user's recorded answer for question i: an ARRAY of selected labels for a
-- multiSelect (possibly empty), or the single picked value (custom text / option
-- label) otherwise, or nil when nothing is picked yet. Callers shape it: the wire
-- wants the array verbatim, the summary joins it.
local function recorded_answer(q, i)
  local question = q.questions[i]
  if question.multiSelect then
    local labels, sel = {}, q.sel[i] or {}
    for oi, opt in ipairs(question.options or {}) do
      if sel[oi] then labels[#labels + 1] = opt.label end
    end
    return labels
  end
  local p = q.picks[i]
  if p and p.kind == "custom" then return p.text
  elseif p and p.kind == "option" then return p.label end
  return nil
end

-- Build the answers map from every question's recorded pick and submit ONE
-- control_response: allow with updatedInput.answers (the § Q-ASK wire shape; reuses
-- send_permission_response's allow path, which sends updatedInput verbatim).
local function submit_question_answers()
  local q = state.qask
  if not q then return end
  local answers = {}
  for i, question in ipairs(q.questions) do
    local ans = recorded_answer(q, i)
    -- multiSelect always records its (possibly empty) array; single-select only
    -- when actually picked (nil = unanswered, leave the key absent).
    if question.multiSelect or ans ~= nil then
      answers[question.question] = ans
    end
  end
  local merged = vim.deepcopy(q.input or {})
  merged.answers = answers
  send_permission_response(q.request_id, "allow", { input = merged })
  local n = #q.questions
  close_question_card(
    "✓ Answered " .. n .. (n == 1 and " question" or " questions"), "ClaudeQuestion")
end

-- After recording a pick: submit if EVERY question is now answered, else advance to
-- the next still-unanswered question (wrapping from the current one) so the user is
-- always moved toward completion.
local function advance_or_submit()
  local q = state.qask
  if not q then return end
  local n = #q.questions
  -- Walk forward from the current question to the next still-unanswered one
  -- (wrapping). The walk visits all n, so if it finds none every question is
  -- answered → submit.
  for step = 1, n do
    local cand = (q.qi - 1 + step) % n + 1
    if not question_answered(q, cand) then
      q.qi = cand
      render_question_card()
      return
    end
  end
  submit_question_answers()
end

-- Cancel the whole card: allow WITH NO answers (the clean dismiss — the CLI emits
-- a "Question dismissed, no answer" tool_result and the model continues/re-asks).
local function cancel_question()
  local q = state.qask
  if not q then return end
  send_permission_response(q.request_id, "allow", { input = q.input })
  close_question_card("✗ Questions dismissed", "ClaudeDim")
end
Question.cancel_question = cancel_question

-- Per-question "Questions asked:" summary that rides in the "Chat about this"
-- feedback (the bundle's t_m): each question text on its own line, followed by the
-- recorded answer (joined labels for multiSelect, the picked/custom value otherwise)
-- or "(No answer provided)" when the user hit Chat before answering it.
local function question_summary(q)
  local parts = {}
  for i, question in ipairs(q.questions) do
    parts[#parts + 1] = '- "' .. (question.question or "") .. '"'
    local ans = recorded_answer(q, i)
    -- multiSelect returns an array — join it, or drop to nil when nothing selected
    -- so it reads "(No answer provided)" like an unpicked single-select.
    if question.multiSelect then
      ans = #ans > 0 and table.concat(ans, ", ") or nil
    end
    parts[#parts + 1] = ans and ("  Answer: " .. ans) or "  (No answer provided)"
  end
  return table.concat(parts, "\n")
end

-- "Chat about this": NOT a dismiss. The TUI sends a `behavior:"deny"` whose `message`
-- carries the canned clarify text (verbatim from the bundle's e_m `feedback`, which
-- serializes to `message` on the wire) + the question summary, so the model opens a
-- clarification dialogue instead of silently moving on. Reusing cancel_question's
-- allow-no-answers (the first bug) was a dismiss; sending it as `feedback` (the second
-- bug) was dropped → bare deny → model saw "permission denied". § Q-ASK addendum.
local function respond_to_claude_question()
  local q = state.qask
  if not q then return end
  local message = "The user wants to clarify these questions. This means they may "
    .. "have additional information, context or questions for you. Take their "
    .. "response into account and then reformulate the questions if appropriate. "
    .. "Start by asking them what they would like to clarify. Questions asked: "
    .. question_summary(q)
  send_permission_response(q.request_id, "deny", { message = message })
  -- close_question_card reopens the dismissed chat bar (draft restored) so the user
  -- can immediately type their clarification once the model asks.
  close_question_card("💬 Chat about this", "ClaudeQuestion")
end
Question.respond_to_claude_question = respond_to_claude_question

-- Record a free-text custom answer for the current question, then advance/submit.
-- nil text = the input was cancelled → leave the card untouched.
local function set_question_custom(text)
  local q = state.qask
  if not q or text == nil then return end
  q.picks[q.qi] = { kind = "custom", text = text }
  advance_or_submit()
end
Question.set_question_custom = set_question_custom

-- Open a small input for the "Type something" affordance. A dedicated, FOCUSED
-- float in the panel column (NOT vim.ui.input): dressing routes vim.ui.input to a
-- cursor-relative float that opened behind the question card (the card holds focus
-- + a higher draw position), so the user's typing landed in an invisible window.
-- This float anchors SW at the panel column with a zindex ABOVE the card (70 > 60),
-- focused + in insert mode, so what's typed is always visible. <CR> commits the
-- answer, <Esc> cancels back to the card. Empty/cancelled input just repaints.
local function prompt_question_custom()
  if not state.qask then return end
  -- Shared geometry: anchors to the panel's real screen column (same fix
  -- open_question_float already got — this path was still using columns-panel_w,
  -- which drifts when the panel isn't flush-right).
  local float_col, float_w = panel_float_geom()

  -- A prompt buffer (not a plain scratch) so it carries the same green "❯" arrow as
  -- the chat bar: prompt_setprompt draws the arrow, matchadd colours it terminal-
  -- green (ClaudeArrow), and <CR> fires prompt_setcallback with the typed text.
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile  = false
  vim.bo[buf].buftype   = "prompt"

  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    anchor    = "SW",
    row       = widgets.float_bottom_row(),
    col       = float_col,
    width     = float_w,
    height    = 1,
    border    = "rounded",
    style     = "minimal",
    title     = " ✎ Type your answer ",
    title_pos = "left",
    zindex    = 70,
  })
  vim.wo[win].winhighlight =
    "FloatBorder:ClaudeBarBorder,FloatTitle:ClaudeBarBorder,NormalFloat:ClaudeBarBg"
  vim.wo[win].wrap = false

  -- Green "❯ " prompt arrow, matching the chat bar (window-local match, set while
  -- this float is the current window).
  vim.fn.prompt_setprompt(buf, "❯ ")
  vim.fn.matchadd("ClaudeArrow", "^❯")
  -- Show the cursor while typing (the panel hides it globally via guicursor).
  vim.o.guicursor = state.real_guicursor or "a:block,a:blinkon0"

  -- Close the input, then either record the typed text (commit + advance/submit)
  -- or fall back to the card untouched. Refocus the card so navigation continues.
  -- Guarded so the prompt callback + an <Esc>/WinLeave can't both fire it.
  local done = false
  local function finish(text)
    if done then return end
    done = true
    vim.o.guicursor = "a:ver1-ClaudeCursorHidden"    -- re-hide; focus returns to panel
    if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
    if not state.qask then return end                -- card gone while typing
    if state.qask.win and vim.api.nvim_win_is_valid(state.qask.win) then
      pcall(vim.api.nvim_set_current_win, state.qask.win)
    end
    -- Closing the prompt float leaves the editor in insert mode; the card's
    -- keymaps are normal-mode, so without this the arrows are dead until the user
    -- drops out of insert manually.
    vim.cmd("stopinsert")
    if text and text ~= "" then set_question_custom(text)
    else render_question_card() end
  end

  vim.fn.prompt_setcallback(buf, function(text) finish(text) end)
  local opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("i", "<Esc>", function() finish(nil) end, opts)
  vim.keymap.set("n", "<Esc>", function() finish(nil) end, opts)
  vim.cmd("startinsert!")
end

-- Act on the highlighted option: "Chat about this" denies with feedback (clarify
-- dialogue), "Type something" opens the input, a model option records the pick
-- (single-select) or confirms the multiSelect set, then advances / submits.
local function select_question_choice()
  local q = state.qask
  if not q then return end
  local question = q.questions[q.qi]
  local d = question_display_options(question)[q_choice(q)]
  if not d then return end
  if d.kind == "chat" then
    respond_to_claude_question()
    return
  elseif d.kind == "custom" then
    prompt_question_custom()
    return
  end
  -- model option
  if question.multiSelect then
    q.picks[q.qi] = { kind = "multi" }               -- confirmed; labels live in sel
  else
    q.picks[q.qi] = { kind = "option", index = d.index, label = d.label }
  end
  advance_or_submit()
end
Question.select_question_choice = select_question_choice

-- Build + open the focused, bordered question float (clay border, like the chat
-- bar, since this is a normal interaction, not a warning) and bind its keymaps.
-- render_question_card fills the body + sizes the height for the first question.
local function open_question_float(q)
  -- Shared geometry: anchors to the panel's real screen column (fixes the drift the
  -- permission float already fixed — this path was still using columns-panel_w).
  local float_col, float_w = panel_float_geom()

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile  = false
  q.buf = buf

  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    anchor    = "SW",
    row       = widgets.float_bottom_row(),
    col       = float_col,
    width     = float_w,
    height    = 1,                                   -- render_question_card resizes
    border    = "rounded",
    style     = "minimal",
    title     = " ❓ Question ",
    title_pos = "left",
    zindex    = 60,
  })
  q.win = win
  vim.wo[win].winhighlight =
    "FloatBorder:ClaudeBarBorder,FloatTitle:ClaudeBarBorder,NormalFloat:ClaudeBarBg"
  vim.wo[win].wrap        = true
  vim.wo[win].linebreak   = true
  vim.wo[win].breakindent = true
  vim.wo[win].cursorline  = false
  harden_float_scroll(win)         -- BUG A: no over-scroll past the option list
  -- BUG B: track the panel column/width on resize; re-render to re-fit height+pad.
  q.resize_close = attach_panel_float_resize(win, "ClaudeQaskFloat", function()
    render_question_card()
  end)

  local function map(k, fn)
    vim.keymap.set("n", k, fn, { buffer = buf, nowait = true, silent = true })
  end
  map("<Up>",      function() move_question_choice(-1) end)
  map("k",         function() move_question_choice(-1) end)
  map("<Down>",    function() move_question_choice(1) end)
  map("j",         function() move_question_choice(1) end)
  map("<Tab>",     next_question)
  map("<Right>",   next_question)
  map("<S-Tab>",   prev_question)
  map("<Left>",    prev_question)
  map("<Space>",   toggle_question_choice)
  map("<CR>",      select_question_choice)
  map("<Esc>",     cancel_question)
  map("q",         cancel_question)

  -- Float vanished by some path OTHER than our teardown (which nils state.qask
  -- first) → cancel so the CLI isn't left blocked on the turn.
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once    = true,
    callback = function()
      if state.qask and state.qask.win == win then cancel_question() end
    end,
  })
end

-- Arm a question card from an inbound AskUserQuestion can_use_tool control_request.
-- Pauses the spinner (Claude is blocked on us) and dismisses any open chat bar
-- (same SW-column collision as the permission card), reopened on close.
local function show_question_card(event)
  local req = event.request or {}
  local input = req.input or {}
  local q = {
    request_id = event.request_id,
    input      = input,
    questions  = input.questions or {},
    qi         = 1,
    choice     = {},     -- choice[i] = highlighted display-option index per question
    sel        = {},     -- sel[i]    = { [modelOptIndex] = true } per multiSelect question
    picks      = {},     -- picks[i]  = recorded answer per question (see question_answered)
  }
  if #q.questions == 0 then
    -- Nothing to ask — allow with no answers so the turn isn't left blocked.
    send_permission_response(event.request_id, "allow", { input = input })
    return
  end

  stop_spinner()
  core.pause_turn()   -- freeze the turn clock: the CLI is blocked on the user's answer
  clear_hint()

  state.qask_reopen_bar = false
  if state.chat_win and vim.api.nvim_win_is_valid(state.chat_win) then
    state.qask_reopen_bar = true
    if state.chat_close then pcall(state.chat_close) end
  end

  state.qask = q
  open_question_float(q)
  render_question_card()
  -- Spinner is stopped for the question card, so paint the frozen "Waiting…" hint
  -- ourselves (sits above the card thanks to the reserved pad).
  if set_waiting_hint then set_waiting_hint() end
end
Question.show_question_card = show_question_card

return Question
