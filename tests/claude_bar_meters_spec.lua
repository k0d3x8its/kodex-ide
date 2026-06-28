-- tests/claude_bar_meters_spec.lua
-- Regression: the chat-bar burn meters must stay anchored BELOW the input, even
-- when a multi-line paste adds rows. The old code anchored the meter virtual line
-- to line 0, so a paste rendered the meters in the MIDDLE of the text (and they
-- scrolled off the top once the input grew). render_meters now anchors to the
-- last input line; this spec drives the real open_chat_float and inspects where
-- the meter extmark lands after a multi-line change.
-- Run: nvim --headless -u NONE --cmd "set runtimepath+=." -c "luafile tests/claude_bar_meters_spec.lua"

local H = dofile("tests/helpers.lua")
H.stub_project_root("/tmp")

package.loaded["utils.term_layout"] = { place_vertical = function() end }
package.loaded["utils.claude_diff"] = {
  on_panel_open = function() end, on_panel_close = function() end,
  on_diff_open = function() end, on_diff_close = function() end,
}
package.loaded["utils.opencode"] = {
  state = { opencode_active = false }, toggle = function() end,
}
-- Stub the burn reader so a meter row is always produced (real reader returns nil
-- when ~/.claude/kos-burn-bar-state.json is absent, which would skip the extmark).
package.loaded["utils.claude_burn"] = {
  chunks = function() return { { "5h ", "ClaudeBurnLabel" }, { "████", "ClaudeBurnOk" } } end,
  model  = function() return "" end,
}

local claude = require("utils.claude")
claude.setup({ width_pct = 0.40 })

claude._open_chat_float("Reply to Claude", function() end, { persist_draft = true })
local ibuf = vim.api.nvim_get_current_buf()

-- Simulate a multi-line paste: replace the input with several lines, then fire the
-- text-change autocmd the float listens on.
vim.api.nvim_buf_set_lines(ibuf, 0, -1, false, { "line one", "line two", "line three" })
vim.api.nvim_exec_autocmds("TextChangedI", { buffer = ibuf })
vim.wait(20)

local ns    = vim.api.nvim_create_namespace("claude_bar_meters")
local marks = vim.api.nvim_buf_get_extmarks(ibuf, ns, 0, -1, {})
local last  = vim.api.nvim_buf_line_count(ibuf) - 1

H.check("meter extmark exists", #marks >= 1, "count=" .. #marks)
H.check("meter anchored to LAST input line (not mid-text)",
  #marks >= 1 and marks[1][2] == last,
  "mark row=" .. (marks[1] and marks[1][2] or "nil") .. " last=" .. last)

H.summary("claude_bar_meters")
