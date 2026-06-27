-- tests/claude_draft_spec.lua
-- Exercises the REAL open_chat_float (via claude._open_chat_float) for the
-- unsent-text-draft behaviour: a half-typed "Reply to Claude" message must
-- survive a hide/show of the chat bar, and clear only when sent or deleted.
--
-- Unlike claude_spec.lua, this spec does NOT stub _open_chat_float — it opens
-- the real interactive prompt float so the save-on-close / restore-on-open path
-- runs. It cannot fire a real <CR> headlessly (see claude_spec note), so the
-- submit-clears-draft case is covered by deleting the text instead (the other
-- half of "preserved until deleted or sent").
-- Run: nvim --headless -u NONE --cmd "set runtimepath+=." -c "luafile tests/claude_draft_spec.lua"

local H = dofile("tests/helpers.lua")
H.stub_project_root("/tmp")

-- Minimal stubs so the module loads under -u NONE (mirrors claude_spec.lua).
package.loaded["utils.term_layout"] = { place_vertical = function() end }
package.loaded["utils.claude_diff"] = {
  on_panel_open = function() end, on_panel_close = function() end,
  on_diff_open = function() end, on_diff_close = function() end,
}
package.loaded["utils.opencode"] = {
  state = { opencode_active = false }, toggle = function() end,
}

local claude = require("utils.claude")
claude.setup({ width_pct = 0.40 })

-- Open the real chat float and return its prompt buffer (the focused window's
-- buffer right after open). persist_draft is what the "Reply to Claude" bar uses.
local function open_bar()
  claude._open_chat_float("Reply to Claude", function() end, { persist_draft = true })
  return vim.api.nvim_get_current_buf()
end

-- Hide the bar WITHOUT submitting, the way losing focus does: fire the buffer's
-- WinLeave autocmd, which runs close() → saves the draft and wipes the buffer.
local function hide_bar(buf)
  vim.api.nvim_exec_autocmds("WinLeave", { buffer = buf })
  vim.wait(20)
end

local function input_line(buf)
  return vim.api.nvim_buf_get_lines(buf, -2, -1, false)[1] or ""
end

-- ── Test 1: a half-typed message is saved on a non-submit close ───────────────
local b1 = open_bar()
vim.api.nvim_buf_set_lines(b1, 0, -1, false, { "half typed message" })
hide_bar(b1)
H.check("draft saved on hide", claude.state.chat_draft == "half typed message",
  "got: " .. vim.inspect(claude.state.chat_draft))

-- ── Test 2: the saved draft is restored into the bar on reopen ────────────────
local b2 = open_bar()
H.check("draft restored into reopened bar", input_line(b2) == "half typed message",
  "got: " .. vim.inspect(input_line(b2)))

-- ── Test 3: deleting the text and closing clears the draft (the "deleted" half) ─
vim.api.nvim_buf_set_lines(b2, 0, -1, false, { "" })
hide_bar(b2)
H.check("draft cleared when text deleted", claude.state.chat_draft == "",
  "got: " .. vim.inspect(claude.state.chat_draft))

-- ── Test 4: a fresh bar after a cleared draft opens empty ─────────────────────
local b3 = open_bar()
H.check("reopened bar empty after clear", input_line(b3) == "",
  "got: " .. vim.inspect(input_line(b3)))
hide_bar(b3)

H.summary("claude_draft")
