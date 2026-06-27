-- tests/claude_expand_spec.lua
-- Run: nvim --headless -u NONE --cmd "set runtimepath+=." -c "luafile tests/claude_expand_spec.lua"
--
-- Regression for the chat-bar expand glitch (TODOS [BUG][UX]): when the input
-- wraps to a new screen row the float must grow in the SAME tick as the keystroke.
-- The old 16ms debounce on fit_height_now left a frame where the buffer had
-- wrapped but the float hadn't grown — too short, the window scrolled the "❯"
-- prompt off the top and the wrapped text flashed up where the arrow had been.
--
-- This spec drives the REAL open_chat_float (NOT the stub claude_spec uses) so it
-- exercises fit_height_now/apply_layout/nvim_win_set_config at the true call site.

local H = dofile("tests/helpers.lua")
H.stub_project_root("/tmp")
package.loaded["utils.term_layout"] = { place_vertical = function() end }
package.loaded["utils.claude_diff"] = {
  on_panel_open = function() end, on_panel_close = function() end,
  on_diff_open = function() end, on_diff_close = function() end,
}
package.loaded["utils.opencode"] = { state = { opencode_active = false }, toggle = function() end }

vim.fn.jobstart = function(_, _) return 99 end
vim.fn.jobstop = function() end
vim.fn.chansend = function(_, d) return #d end
vim.fn.chanclose = function() end

local claude = require("utils.claude")
claude.setup({ width_pct = 0.40 })
claude.is_available = function() return true end

vim.o.lines = 30
vim.o.columns = 120
vim.cmd("cd /tmp")
claude.toggle(); vim.wait(50)
claude.state.job_id = nil
claude.state.working = false

-- Open the REAL chat float; callback is a no-op (we never submit).
claude._open_chat_float("Reply to Claude", function() end)
vim.wait(30)

-- Locate the float window + its prompt buffer (the floating win that isn't the panel).
local fwin, ibuf
for _, w in ipairs(vim.api.nvim_list_wins()) do
  local cfg = vim.api.nvim_win_get_config(w)
  if cfg.relative ~= "" and w ~= claude.state.panel_win then
    fwin = w; ibuf = vim.api.nvim_win_get_buf(w)
  end
end
H.check("chat float opened", fwin ~= nil and ibuf ~= nil)

local float_w = vim.api.nvim_win_get_width(fwin)

-- Type a line long enough to wrap to a 2nd screen row, then fire the event an
-- interactive keystroke fires.
local long = string.rep("x", float_w + 10)
vim.api.nvim_buf_set_lines(ibuf, 0, -1, false, { long })
vim.api.nvim_win_set_cursor(fwin, { 1, #long })
vim.api.nvim_exec_autocmds("TextChangedI", { buffer = ibuf })

-- The frame the user sees: immediately after the change, with NO wait for any timer.
local h_immediate = vim.api.nvim_win_get_height(fwin)

-- Settle any timer that a regression might reintroduce, then read the resting height.
vim.wait(40)
local h_after = vim.api.nvim_win_get_height(fwin)

-- Wrapped input (2 rows) + meter row (1) = 3.
H.check("wrap grows the float to 3 rows", h_after == 3, "h_after=" .. h_after)
-- The fix: no debounce lag — the float is already at its resting height on the
-- same tick as the keystroke, so there's no too-short flash frame.
H.check("height correct immediately after wrap (no debounce lag)",
  h_immediate == h_after, ("immediate=%d after=%d"):format(h_immediate, h_after))

H.summary("claude_expand")
