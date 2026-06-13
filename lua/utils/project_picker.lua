-- lua/utils/project_picker.lua
-- Shown on dock launch (KODEX_IDE=1). Lets the user pick a project or resume
-- the last session before the OpenCode panel opens.

local mod = {}

-- Scan the auto-session storage dir and return the unescaped project path
-- with the highest mtime, but only considering sessions that correspond to a
-- known ~/dev/* project. This prevents stray sessions (e.g. ~/dev itself, or
-- a tmp dir opened once) from being picked up by "Resume last session".
-- Returns nil when no qualifying session exists yet.
local function latest_project_session(session_dir, projects)
  local best = { name = nil, mtime = 0 }
  local Lib = require("auto-session.lib")

  for _, proj in ipairs(projects) do
    -- auto-session percent-encodes the path as the filename, e.g.
    -- /home/k0d3x/dev/kodex-ide → %2Fhome%2Fk0d3x%2Fdev%2Fkodex-ide.vim
    local filename = Lib.escape_session_name(proj) .. ".vim"
    local mtime = vim.fn.getftime(session_dir .. filename)
    -- getftime returns -1 when the file doesn't exist
    if mtime > best.mtime then
      best.mtime = mtime
      best.name = proj
    end
  end

  return best.name
end

function mod.pick()
  -- auto-session public API: restore_session(name) and get_root_dir()
  local AutoSession = require("auto-session")

  -- Glob ~/dev/*/ to get all immediate project subdirs.
  -- Trailing slash stripped so fnameescape + cd work cleanly.
  local dev_path = vim.fn.expand("~/dev/")
  local raw = vim.fn.glob(dev_path .. "*/", true, true)
  local projects = {}
  for _, dir in ipairs(raw) do
    table.insert(projects, (dir:gsub("/$", "")))
  end

  -- "Resume last session" always appears first; projects follow in glob order.
  local RESUME = "Resume last session"
  local items = { RESUME }
  vim.list_extend(items, projects)

  -- dressing.nvim intercepts vim.ui.select and renders a telescope/fzf picker
  -- automatically — no extra setup needed here.
  vim.ui.select(items, {
    prompt = "Kodex IDE — open project:",
    -- Show only the directory basename; full path is shown in the picker footer
    -- by dressing if the user inspects the raw item.
    format_item = function(item)
      if item == RESUME then return item end
      return vim.fn.fnamemodify(item, ":t")
    end,
  }, function(choice)
    -- nil means the user dismissed the picker — do nothing.
    if not choice then return end

    if choice == RESUME then
      -- get_root_dir() returns the session-storage dir on disk, not a project root.
      -- We search only sessions matching known ~/dev/* projects so that sessions
      -- for parent dirs (~/dev, ~/, etc.) are never accidentally resumed.
      local session_dir = AutoSession.get_root_dir()
      local latest = latest_project_session(session_dir, projects)
      if latest then
        -- restore_session(name) re-escapes the path to locate the session file,
        -- then sources it — which cds and reopens the saved buffers.
        AutoSession.restore_session(latest)
      else
        vim.notify("No project sessions found — pick a project to start one", vim.log.levels.INFO)
      end
    else
      -- Change cwd first so restore_session() (called with no args) resolves
      -- the session file for this project's directory.
      vim.cmd("cd " .. vim.fn.fnameescape(choice))
      -- No session for this project yet → restore_session is a no-op and the
      -- dashboard stays open so the user can start fresh.
      AutoSession.restore_session()
    end

    -- Defer 200 ms: gives the session source() call time to finish opening
    -- buffers before the OpenCode panel is created and pinned to the layout.
    vim.defer_fn(function()
      require("utils.opencode").open()
    end, 200)
  end)
end

return mod
