-- tests/helpers.lua
-- Shared scaffolding for the headless dofile test suite.
-- Each spec runs in its own `nvim --headless -u NONE` (see tests/run.sh), so the
-- counters below are per-spec. Load with: local H = dofile("tests/helpers.lua")

local H = { failures = 0, sent = {} }

-- Quiet the headless session: no swap, suppress "written"/ATTENTION messages.
vim.o.swapfile = false
vim.o.shortmess = vim.o.shortmess .. "A"

-- Stub toggleterm so Terminal:new works under `-u NONE` (the real plugin isn't
-- loaded). on_open is handed the term object — create_term reads term.bufnr.
-- term:send records into H.sent so ask_selection assertions can inspect payloads.
function H.stub_toggleterm()
  H.sent = {}
  package.loaded["toggleterm.terminal"] = {
    Terminal = {
      new = function(_, opts)
        local t = { _opts = opts, _open = false, bufnr = vim.api.nvim_create_buf(false, true) }
        function t:is_open() return self._open end
        function t:toggle()
          if self._open then
            self._open = false
            if self._opts.on_close then self._opts.on_close() end
          else
            self._open = true
            if self._opts.on_open then self._opts.on_open(self) end
          end
        end
        function t:shutdown()
          if self._open then
            self._open = false
            if self._opts.on_close then self._opts.on_close() end
          end
        end
        function t:send(text, _) table.insert(H.sent, text) end
        return t
      end,
    },
  }
end

-- Stub project_root so toggle() never touches vim.fs.root / the real cwd.
function H.stub_project_root(root)
  package.loaded["utils.project_root"] = { detect = function() return root or "/tmp" end }
end

-- Write `lines` to `path` from OUTSIDE Neovim's knowledge (mimics opencode
-- editing a file on disk) so FileChangedShell/checktime have something to catch.
function H.ext_write(path, lines)
  vim.fn.writefile(lines, path)
  -- nudge mtime so a same-second rewrite is still detected as changed
  vim.fn.system({ "touch", path })
end

function H.buf_lines(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "|")
end

function H.check(name, cond, detail)
  if cond then
    print("PASS  " .. name)
  else
    H.failures = H.failures + 1
    print("FAIL  " .. name .. (detail and ("  — " .. tostring(detail)) or ""))
  end
end

-- Print the summary line and exit with a shell-visible status: cq = exit 1.
function H.summary(label)
  print(H.failures == 0 and ("\n" .. label .. ": ALL PASS")
    or ("\n" .. label .. ": " .. H.failures .. " FAILURES"))
  if H.failures > 0 then vim.cmd("cq") else vim.cmd("qa!") end
end

return H
