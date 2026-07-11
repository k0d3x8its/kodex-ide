-- tests/claude_scroll_hold_spec.lua
-- Regression for the over-scroll hunk-band corruption (TODOS 2026-07-11 [BUG]):
-- pet kitty writes race nvim's TUI output on fd 1 (two libuv tty handles, no
-- coordination — proven by a PTY A/B capture: APC writer on = interrupted CSIs +
-- literal ";NNNm" fragments, off = clean). The fix suppresses pet writes during
-- panel scroll storms. This spec pins the INIT side: every panel scroll site
-- (wheel-down pre-empt, wheel-up map, clamp_scroll's bounce correction) must
-- refresh pet_render.hold_writes.
-- Run: nvim --headless -u NONE --cmd "set runtimepath+=." -c "luafile tests/claude_scroll_hold_spec.lua"

local H = dofile("tests/helpers.lua")
H.stub_project_root("/tmp")

vim.fn.jobstart = function(_, _) return 99 end
vim.fn.jobstop  = function() end
vim.fn.chansend = function(_, d) return #d end
vim.fn.chanclose = function() end

package.loaded["utils.term_layout"] = { place_vertical = function() end }
package.loaded["utils.claude_diff"] = {
  on_panel_open = function() end, on_panel_close = function() end,
  on_diff_open  = function() end, on_diff_close  = function() end,
  watch = function() end, poll = function() end,
}
package.loaded["utils.opencode"] = { state = { opencode_active = false }, toggle = function() end }

-- Spy on the hold seam BEFORE init caches its behavior (init requires pet_render
-- at load; the module table is shared, so patching the field is enough).
local pet_render = require("utils.claude.pet_render")
local holds = 0
pet_render.hold_writes = function() holds = holds + 1 end

local claude = require("utils.claude")
claude.setup({ width_pct = 0.40 })
claude.is_available = function() return true end

vim.o.lines = 40
vim.o.columns = 120
vim.cmd("cd /tmp")
claude.toggle(); vim.wait(30)
H.check("SH0 panel open", claude.state.panel_win ~= nil
  and vim.api.nvim_win_is_valid(claude.state.panel_win))

-- Fill the panel so there is real scroll room (well past one window height).
local buf = claude.state.panel_buf
vim.bo[buf].modifiable = true
local lines = {}
for i = 1, 200 do lines[i] = "row " .. i end
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
vim.bo[buf].modifiable = false

-- SH1: wheel-down pre-empt refreshes the hold.
holds = 0
claude._panel_wheel_down()
H.check("SH1 wheel-down holds pet writes", holds >= 1, "holds=" .. holds)

-- SH2: wheel-up map refreshes the hold + scrolls the panel up.
holds = 0
vim.api.nvim_set_current_win(claude.state.panel_win)
vim.api.nvim_win_set_cursor(claude.state.panel_win, { 200, 0 })
vim.cmd("normal! zb")
local top_before = vim.fn.line("w0", claude.state.panel_win)
claude._panel_wheel_up()
local top_after = vim.fn.line("w0", claude.state.panel_win)
H.check("SH2 wheel-up holds pet writes", holds >= 1, "holds=" .. holds)
H.check("SH2b wheel-up scrolls the view up", top_after < top_before,
  "before=" .. top_before .. " after=" .. top_after)

-- SH3: clamp_scroll bounce correction refreshes the hold. Force an over-scroll:
-- <C-e> past the end drags the LAST line up above its resting band (gap > limit),
-- which is exactly the state the WinScrolled clamp corrects with a bounce.
holds = 0
vim.api.nvim_win_call(claude.state.panel_win, function()
  vim.cmd("keepjumps normal! G")
  local so = vim.wo[claude.state.panel_win].scrolloff
  vim.wo[claude.state.panel_win].scrolloff = 0
  local overshoot = (claude.state.pad_rows or 0) + claude._SCROLL_TAIL + 5
  vim.cmd("keepjumps normal! " .. overshoot .. "\005") -- <C-e> ×overshoot
  vim.wo[claude.state.panel_win].scrolloff = so
end)
claude._clamp_scroll()
H.check("SH3 clamp bounce correction holds pet writes", holds >= 1, "holds=" .. holds)

H.summary("claude_scroll_hold_spec")
