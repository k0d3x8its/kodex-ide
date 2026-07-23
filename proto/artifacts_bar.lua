-- ============================================================================
-- PROTOTYPE — THROWAWAY. Delete or absorb into lua/utils/claude/widgets.lua.
-- Question: what should the session-persistent "Artifacts" bar look like, and
-- does click-to-open-in-browser feel right (bar segments + inline transcript
-- link)?
--
-- Run:   nvim -u proto/artifacts_bar.lua
-- Keys:  <Tab> cycle look variant | <LeftMouse> click artifact (bar or inline)
--        1..9  open artifact by number | r simulate <leader>cr clear | q quit
-- NOTE:  opening a URL is STUBBED to an :echo (no real browser tab during proto).
--        Flip REAL_OPEN=true to actually call vim.ui.open.
-- ============================================================================

local REAL_OPEN = false

-- Fake session state -----------------------------------------------------------
-- Mirrors the shape a real state.artifacts would hold: appended per Artifact
-- tool_use, url filled at tool_result. favicon is the emoji the tool carries.
local artifacts = {
  { name = "advisor_tui_mockup", favicon = "◈", url = "https://claude.ai/code/artifact/aaaa-1111" },
  { name = "advisor_tui_ascii",  favicon = "▤", url = "https://claude.ai/code/artifact/bbbb-2222" },
  { name = "burn_meter_redesign",favicon = "▦", url = "https://claude.ai/code/artifact/cccc-3333" },
}

local variant = 3  -- numbered-keyboard is the chosen look; others kept for A/B
local VARIANTS = { "bordered-card", "flush-strip", "numbered-keyboard" }

-- Highlight groups (proto runs with -u so define our own; real code reuses
-- ClaudeNormal / ClaudePermBorder / a new ClaudeArtifact* group) --------------
local function hl()
  vim.api.nvim_set_hl(0, "ProtoBar",     { fg = "#c8d0e0", bg = "#1b1e2b" })
  vim.api.nvim_set_hl(0, "ProtoBarName", { fg = "#7dcfff", bg = "#1b1e2b", underline = true })
  vim.api.nvim_set_hl(0, "ProtoBarIcon", { fg = "#e0af68", bg = "#1b1e2b" })
  vim.api.nvim_set_hl(0, "ProtoBorder",  { fg = "#e0af68", bg = "#1b1e2b" })
  vim.api.nvim_set_hl(0, "ProtoDim",     { fg = "#565f89" })
  vim.api.nvim_set_hl(0, "ProtoLink",    { fg = "#7dcfff", underline = true })
end

-- Open action (stubbed) --------------------------------------------------------
local function open_url(a)
  if not a then return end
  if REAL_OPEN then
    vim.ui.open(a.url)
  else
    vim.api.nvim_echo({ { "would open in browser → ", "ProtoDim" }, { a.url, "ProtoLink" } }, false, {})
  end
end

-- ── The transcript panel (fake) ──────────────────────────────────────────────
local panel_buf, panel_win
-- Records where the inline artifact link lives so a click can resolve it:
-- {lnum, col_start, col_end, artifact_index}
local inline_link

local function build_panel()
  panel_buf = vim.api.nvim_create_buf(false, true)
  local link_a = artifacts[2]  -- pretend the transcript prose linked this one
  -- Nest the published line under the ● Artifact header with a └ corner, aligned
  -- under the header text (mirrors render_tool_result). The corner+prefix are
  -- fixed; the trailing name is the clickable span.
  local link_prefix = "    └ published · "
  local link_label = link_prefix .. link_a.name
  local lines = {
    "",
    "  ● Advising using Opus 4.8",
    "    ✔ Advisor reviewed the conversation.",
    "",
    "  ● Call succeeded. Guidance on testing methodology.",
    "",
    "  ● Artifact  " .. link_a.name .. ".md",
    link_label,
    "",
    "  You see this in your chat — but the real test is whether it renders",
    "  correctly in your Neovim panel.",
    "",
  }
  vim.api.nvim_buf_set_lines(panel_buf, 0, -1, false, lines)
  vim.bo[panel_buf].modifiable = false

  panel_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(panel_win, panel_buf)
  vim.wo[panel_win].number = false
  vim.wo[panel_win].cursorline = false

  -- Highlight the inline link + remember its extent for click resolution.
  local lnum = 7  -- 0-indexed line of link_label ("    └ published · name")
  local cstart = #link_prefix
  local cend = cstart + #link_a.name
  vim.api.nvim_buf_add_highlight(panel_buf, -1, "ProtoLink", lnum, cstart, cend)
  inline_link = { lnum = lnum, cs = cstart, ce = cend, idx = 2 }
end

-- ── The artifacts bar (the thing under test) ─────────────────────────────────
local bar_buf, bar_win
-- Per-variant, records clickable segments: {col_start, col_end, artifact_index}
local segments = {}

local function bar_line_bordered()
  -- Bordered card, title, horizontal favicon+name separated by " · ".
  -- Matches the Task Plan card style already in widgets.lua.
  segments = {}
  local parts, col = {}, 1  -- col 1 = first content cell inside the 1-space pad
  local text = " "
  for i, a in ipairs(artifacts) do
    if i > 1 then text = text .. "   " end
    local seg_start = #text
    text = text .. a.favicon .. " " .. a.name
    local seg_end = #text
    segments[#segments + 1] = { cs = seg_start, ce = seg_end, idx = i }
    parts[i] = a.name
  end
  return { text }, " ◈ Artifacts ", "rounded"
end

local function bar_line_flush()
  -- Borderless single-line strip flush at the very bottom. Denser, no title.
  segments = {}
  local text = "  "
  for i, a in ipairs(artifacts) do
    if i > 1 then text = text .. "    " end
    local seg_start = #text
    text = text .. a.favicon .. " " .. a.name
    segments[#segments + 1] = { cs = seg_start, ce = #text, idx = i }
  end
  return { text }, nil, "none"
end

local function bar_line_numbered()
  -- Keyboard-first: [1] name  [2] name … mirrors the SPC-1..4 file picker in
  -- the screenshot. Click still works but numbers are the affordance.
  segments = {}
  local text = " "
  for i, a in ipairs(artifacts) do
    if i > 1 then text = text .. "  " end
    text = text .. "["
    local seg_start = #text - 1
    text = text .. i .. "] " .. a.name
    segments[#segments + 1] = { cs = seg_start, ce = #text, idx = i }
  end
  return { text }, " ◈ Artifacts (1-9 to open) ", "rounded"
end

local function render_bar()
  if #artifacts == 0 then
    if bar_win and vim.api.nvim_win_is_valid(bar_win) then
      vim.api.nvim_win_close(bar_win, true)
      bar_win = nil
    end
    return
  end

  local lines, title, border
  if variant == 1 then lines, title, border = bar_line_bordered()
  elseif variant == 2 then lines, title, border = bar_line_flush()
  else lines, title, border = bar_line_numbered() end

  if not (bar_buf and vim.api.nvim_buf_is_valid(bar_buf)) then
    bar_buf = vim.api.nvim_create_buf(false, true)
  end
  vim.bo[bar_buf].modifiable = true
  vim.api.nvim_buf_set_lines(bar_buf, 0, -1, false, lines)

  -- Paint icon + name segments.
  vim.api.nvim_buf_clear_namespace(bar_buf, -1, 0, -1)
  for _, s in ipairs(segments) do
    vim.api.nvim_buf_add_highlight(bar_buf, -1, "ProtoBarName", 0, s.cs, s.ce)
  end
  vim.bo[bar_buf].modifiable = false

  local width = vim.o.columns - 4
  local cfg = {
    relative = "editor", anchor = "SW",
    row = vim.o.lines - 2, col = 1,
    width = math.max(width, 10), height = #lines,
    style = "minimal", focusable = false, zindex = 30,
    border = border,
  }
  if title then cfg.title, cfg.title_pos = title, "left" end

  if bar_win and vim.api.nvim_win_is_valid(bar_win) then
    vim.api.nvim_win_set_config(bar_win, cfg)
  else
    bar_win = vim.api.nvim_open_win(bar_buf, false, cfg)
  end
  vim.wo[bar_win].winhl = "Normal:ProtoBar,FloatBorder:ProtoBorder,FloatTitle:ProtoBorder"
end

-- ── Click resolution ─────────────────────────────────────────────────────────
local function on_click()
  local m = vim.fn.getmousepos()
  -- Bar is keyboard-only (1-9 to open) — no mouse resolution. Only the inline
  -- transcript link is clickable. Click landed on it?
  if inline_link and m.winid == panel_win then
    local lnum0 = m.line - 1
    local c = m.column - 1
    if lnum0 == inline_link.lnum and c >= inline_link.cs and c < inline_link.ce then
      open_url(artifacts[inline_link.idx])
    end
  end
end

-- ── Wiring ────────────────────────────────────────────────────────────────────
local function cycle_variant()
  variant = variant % #VARIANTS + 1
  render_bar()
  vim.api.nvim_echo({ { "variant → ", "ProtoDim" }, { VARIANTS[variant], "ProtoBarIcon" } }, false, {})
end

local function clear_session()  -- simulate <leader>cr
  artifacts = {}
  render_bar()
  vim.api.nvim_echo({ { "session cleared — artifacts bar gone", "ProtoDim" } }, false, {})
end

local function setup()
  vim.o.mouse = "a"
  vim.o.laststatus = 0
  vim.o.cmdheight = 1
  hl()
  build_panel()
  render_bar()

  local map = function(lhs, fn) vim.keymap.set("n", lhs, fn, { silent = true }) end
  -- Leave <LeftMouse> default (positions cursor); resolve on release via
  -- getmousepos() so the click still lands wherever the user pressed.
  map("<LeftRelease>", on_click)
  map("<Tab>", cycle_variant)
  map("r", clear_session)
  map("q", function() vim.cmd("qa!") end)
  for i = 1, 9 do
    map(tostring(i), function() open_url(artifacts[i]) end)
  end

  vim.api.nvim_create_autocmd("VimResized", { callback = render_bar })

  vim.api.nvim_echo({
    { "PROTOTYPE artifacts bar  ", "ProtoBarIcon" },
    { "<Tab> variant · click/1-9 open · r clear · q quit", "ProtoDim" },
  }, false, {})
end

setup()
