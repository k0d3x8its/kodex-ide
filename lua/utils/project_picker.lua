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

-- After the project root is resolved, open the file-tree sidebar and arrange
-- for the OpenCode panel to launch when the user opens their first file.
-- User decision (2026-06-13): OpenCode starts AFTER a file is chosen, seeded
-- with that file, rather than immediately on project pick.
local function open_workspace(proj)
  -- Resumed session: a real file window is already open. Launch OpenCode now,
  -- seeded with that file. Do NOT open the sidebar — the tree is only wanted on
  -- a fresh session (user decision 2026-06-13).
  local file_win
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(win)
    if vim.bo[b].buftype == "" and vim.api.nvim_buf_get_name(b) ~= "" then
      file_win = win
      break
    end
  end

  if file_win then
    vim.api.nvim_set_current_win(file_win)
    require("utils.opencode").open()
    return
  end

  -- Fresh project: open the sidebar rooted at the project. OpenCode launches
  -- when the user opens their first file (one-shot BufWinEnter), seeded with it.
  -- After it launches, focus returns to the sidebar so the user is NOT dropped
  -- into OpenCode's insert prompt — they close the tree manually when ready.
  local group = vim.api.nvim_create_augroup("KodexOpenCodeFirstFile", { clear = true })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function(args)
      -- only real file buffers — skip terminals, [No Name], dashboard, tree
      if vim.bo[args.buf].buftype ~= "" then return end
      if vim.api.nvim_buf_get_name(args.buf) == "" then return end
      local ft = vim.bo[args.buf].filetype
      if ft == "alpha" or ft == "NvimTree" then return end
      vim.api.nvim_del_augroup_by_id(group)
      require("utils.opencode").open()
      -- Return focus to the sidebar instead of OpenCode's insert prompt.
      -- Deferred so it runs after toggleterm finishes opening + entering insert.
      vim.schedule(function()
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "NvimTree" then
            vim.api.nvim_set_current_win(win)
            vim.cmd("stopinsert") -- belt-and-suspenders: leave terminal insert
            break
          end
        end
      end)
    end,
  })

  -- Open the file-tree rooted at the project so the user can pick a file.
  -- change_root is explicit because tree.open reuses its initial root (the
  -- startup cwd, e.g. ~/dev) instead of the project the picker cd'd into.
  local tree_api = require("nvim-tree.api")
  tree_api.tree.open()
  tree_api.tree.change_root(proj)
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

    local proj
    if choice == RESUME then
      -- get_root_dir() returns the session-storage dir on disk, not a project root.
      -- We search only sessions matching known ~/dev/* projects so that sessions
      -- for parent dirs (~/dev, ~/, etc.) are never accidentally resumed.
      local session_dir = AutoSession.get_root_dir()
      local latest = latest_project_session(session_dir, projects)
      if not latest then
        vim.notify("No project sessions found — pick a project to start one", vim.log.levels.INFO)
        return
      end
      -- restore_session(name) re-escapes the path to locate the session file,
      -- then sources it — which cds and reopens the saved buffers.
      AutoSession.restore_session(latest)
      proj = latest
    else
      -- Change cwd first so restore_session() (called with no args) resolves
      -- the session file for this project's directory.
      vim.cmd("cd " .. vim.fn.fnameescape(choice))
      -- No session for this project yet → restore_session is a no-op and the
      -- dashboard stays open so the user can start fresh.
      AutoSession.restore_session()
      proj = choice
    end

    -- Defer 200 ms: gives the session source() call time to finish opening
    -- buffers before we inspect the window layout and open the sidebar.
    vim.defer_fn(function()
      open_workspace(proj)
    end, 200)
  end)
end

return mod
