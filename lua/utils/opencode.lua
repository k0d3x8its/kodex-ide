-- lua/utils/opencode.lua

local mod = {}

-- Full path required: ~/.opencode/bin is only on PATH in interactive bash,
-- never in Neovim's environment (findings Q12)
mod.OPENCODE_BIN = vim.fn.expand("~/.opencode/bin/opencode")

--- Guard used before any panel toggle (findings Q8)
---@return boolean
function mod.is_available()
  return vim.fn.executable(mod.OPENCODE_BIN) == 1
end

return mod
