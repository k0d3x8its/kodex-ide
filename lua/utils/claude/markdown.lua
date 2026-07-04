-- lua/utils/claude/markdown.lua
--
-- The panel's markdown render engine: string → (display lines, per-line highlight
-- span lists). Nearly pure — the only outside dependency is core.panel_width (wrap
-- width) plus optional nvim-web-devicons + treesitter probes, both pcall-guarded.
-- Extracted verbatim from the former monolithic claude.lua (Goal 15.2).
--
-- Entry point: build_md_lines(raw_lines) → clean_lines, per_line_hls. Also exposes
-- render_table / render_code_block / is_fence / wrap_text / disp_take for the code
-- paths in init.lua that call them directly.

local Markdown = {}

local require_prefix = "utils.claude."
local core = require(require_prefix .. "core")
local panel_width = core.panel_width

-- Decide the display text + highlight group for an inline `…` span. Priority:
--   1. Known file type → its nvim-web-devicons glyph + the language's DevIcon
--      highlight group (correct brand/theme colour), e.g. `init.lua` → " init.lua"
--      in DevIconLua blue. Falls back gracefully when devicons isn't loaded.
--   2. [bracket] tag       → ClaudeBracket (pink)
--   3. path (~ ./ or has /) → ClaudePath (green)
--   4. anything else        → ClaudeCode (cyan)
-- Returns: display_text, hl_group.
local function span_style(inner)
  local fname = inner:match("([^/%s]+)$")          -- basename of a path
  local ext   = fname and fname:match("%.([%w]+)$")
  if ext then
    local ok, dev = pcall(require, "nvim-web-devicons")
    if ok then
      local icon, hl = dev.get_icon(fname, ext, { default = false })
      if icon and hl then
        return icon .. " " .. inner, hl
      end
    end
  end
  if inner:match("^%[.*%]$") then return inner, "ClaudeBracket" end
  if inner:match("^~") or inner:match("^%.?%./") or inner:find("/", 1, true) then
    return inner, "ClaudePath"
  end
  return inner, "ClaudeCode"
end

-- Parse one line of inline markdown, STRIPPING the markers (so the panel reads
-- like rendered markdown, not raw text) and recording highlight ranges over the
-- cleaned line. Handles **bold** → ClaudeBold and `code` → ClaudeCode.
-- Returns: clean_line, { {byte_start0, byte_end, group}, ... }  (byte offsets are
-- 0-indexed start / end-exclusive, matching nvim_buf_add_highlight).
local function parse_inline(line)
  local parts, hls, blen, i, n = {}, {}, 0, 1, #line
  while i <= n do
    if line:sub(i, i + 1) == "**" then
      local close = line:find("**", i + 2, true)
      if close then
        local inner = line:sub(i + 2, close - 1)
        parts[#parts + 1] = inner
        hls[#hls + 1] = { blen, blen + #inner, "ClaudeBold" }
        blen = blen + #inner
        i = close + 2
      else
        parts[#parts + 1] = "**"; blen = blen + 2; i = i + 2
      end
    elseif line:sub(i, i) == "`" then
      local close = line:find("`", i + 1, true)
      if close then
        local inner = line:sub(i + 1, close - 1)
        -- span_style picks the display text (with a file glyph when it's a known
        -- file type) and the colour (DevIcon / bracket / path / code).
        local disp, group = span_style(inner)
        parts[#parts + 1] = disp
        hls[#hls + 1] = { blen, blen + #disp, group }
        blen = blen + #disp
        i = close + 1
      else
        parts[#parts + 1] = "`"; blen = blen + 1; i = i + 1
      end
    elseif line:sub(i, i) == "[" then
      -- Bracketed spans (e.g. [VERIFY], [link text]) — kept verbatim (brackets
      -- are meaningful) but coloured distinctly from inline code so they don't
      -- read as teal. Requires a closing "]" on the same line.
      local close = line:find("]", i + 1, true)
      if close then
        local seg = line:sub(i, close)        -- includes the [ and ]
        parts[#parts + 1] = seg
        hls[#hls + 1] = { blen, blen + #seg, "ClaudeBracket" }
        blen = blen + #seg
        i = close + 1
      else
        parts[#parts + 1] = "["; blen = blen + 1; i = i + 1
      end
    else
      local c = line:sub(i, i)
      parts[#parts + 1] = c; blen = blen + #c; i = i + 1
    end
  end
  return table.concat(parts), hls
end

-- ─── Markdown table rendering ────────────────────────────────────────────────

-- A markdown table row: trimmed line that starts with "|".
local function is_table_row(s) return s:match("^%s*|") ~= nil end

-- A table separator row (|---|:--:|): only |, -, :, spaces.
local function is_table_sep(s)
  return is_table_row(s) and (s:gsub("[%s|:%-]", "") == "") and s:find("%-") ~= nil
end

-- Split "| a | b |" into trimmed cell strings (drops the outer pipes).
local function split_row(s)
  s = s:gsub("^%s*|", ""):gsub("|%s*$", "")
  local cells = {}
  for cell in (s .. "|"):gmatch("(.-)|") do
    cells[#cells + 1] = cell:match("^%s*(.-)%s*$")
  end
  return cells
end

-- Box-drawing glyphs for the table frame (all U+250x, 3 bytes each in UTF-8).
local TBL = {
  H = "─", V = "│",
  TL = "┌", TM = "┬", TR = "┐",   -- top    rule corners/tee
  ML = "├", MM = "┼", MR = "┤",   -- header divider corners/tee
  BL = "└", BM = "┴", BR = "┘",   -- bottom rule corners/tee
}

-- One horizontal rule line (top / header divider / bottom). Each column gets
-- widths[c] + 2 horizontal glyphs (the +2 is the one-space pad on each side of
-- the cell text). Whole line is dimmed.
local function table_rule(left, mid, right, widths)
  local segs = { left }
  for c = 1, #widths do
    segs[#segs + 1] = string.rep(TBL.H, widths[c] + 2)
    segs[#segs + 1] = (c < #widths) and mid or right
  end
  local line = table.concat(segs)
  return line, { { 0, #line, "ClaudeDim" } }
end

-- One content line "│ a │ b │" with shifted cell highlights. is_header bolds the
-- Take a leading prefix of `s` whose DISPLAY width is ≤ w (always ≥ 1 char so a
-- hard-break can't stall). UTF-8 aware: steps whole codepoints, not bytes.
local function disp_take(s, w)
  local out, dw, i = "", 0, 1
  while i <= #s do
    local b   = s:byte(i)
    local len = (b < 0x80 and 1) or (b < 0xE0 and 2) or (b < 0xF0 and 3) or 4
    local ch  = s:sub(i, i + len - 1)
    local cw  = vim.fn.strdisplaywidth(ch)
    if dw + cw > w then break end
    out = out .. ch; dw = dw + cw; i = i + len
  end
  if out == "" then out = s:sub(1, 1) end             -- always consume ≥ 1 byte
  return out
end

-- Word-wrap `s` to display width `w`, hard-breaking any single token wider than
-- the column. Returns a list of sub-lines (at least one).
local function wrap_text(s, w)
  if w < 1 then w = 1 end
  if vim.fn.strdisplaywidth(s) <= w then return { s } end
  local lines, cur = {}, ""
  for word in s:gmatch("%S+") do
    local cand = (cur == "") and word or (cur .. " " .. word)
    if vim.fn.strdisplaywidth(cand) <= w then
      cur = cand
    else
      if cur ~= "" then lines[#lines + 1] = cur; cur = "" end
      while vim.fn.strdisplaywidth(word) > w do      -- hard-break long tokens
        local part = disp_take(word, w)
        lines[#lines + 1] = part
        word = word:sub(#part + 1)
      end
      cur = word
    end
  end
  if cur ~= "" then lines[#lines + 1] = cur end
  if #lines == 0 then lines = { "" } end
  return lines
end

-- Render a run of markdown table rows into display lines + highlight ranges,
-- drawn as a real box-framed table: a top rule, the (bold) header row, a header
-- divider, the body rows, and a bottom rule. Frame glyphs are dimmed; cell text
-- is inline-parsed so paths/code/brackets keep their colours. The |---| markdown
-- separator row is dropped.
--
-- Width-fitting: a naive table can be far wider than the panel, which makes
-- Neovim hard-wrap each line and shatter the box. So column widths are capped to
-- fit panel_width() — the widest column is shaved repeatedly until the frame
-- fits — and over-long cells WRAP onto extra physical rows inside the box (the
-- row's height = its tallest wrapped cell). Returns out_lines, out_hls.
local function render_table(rows)
  -- Raw (unparsed) cell strings per row — parsing is deferred until after
  -- wrapping so highlight offsets line up with each wrapped sub-line.
  local raw_rows, ncols = {}, 0
  for _, r in ipairs(rows) do
    if not is_table_sep(r) then
      local cells = split_row(r)
      ncols = math.max(ncols, #cells)
      raw_rows[#raw_rows + 1] = cells
    end
  end
  if #raw_rows == 0 then return {}, {} end

  -- Natural (uncapped) column display widths.
  local widths = {}
  for c = 1, ncols do widths[c] = 0 end
  for _, cells in ipairs(raw_rows) do
    for c = 1, ncols do
      local w = vim.fn.strdisplaywidth(cells[c] or "")
      if w > widths[c] then widths[c] = w end
    end
  end

  -- Cap to the panel: frame overhead is each column's two pad spaces + its right
  -- border (3) plus the one leading border (1). Shave the widest column until the
  -- content fits the remaining budget.
  local avail   = math.max(panel_width() - 2, 20)
  local budget  = avail - (ncols * 3 + 1)
  if budget >= ncols then
    local total = 0
    for c = 1, ncols do total = total + widths[c] end
    while total > budget do
      local mi, mv = 1, widths[1]
      for c = 2, ncols do if widths[c] > mv then mi, mv = c, widths[c] end end
      widths[mi] = widths[mi] - 1
      total = total - 1
    end
  end
  for c = 1, ncols do if widths[c] < 1 then widths[c] = 1 end end

  local out_lines, out_hls = {}, {}
  local function push(line, hls) out_lines[#out_lines + 1] = line; out_hls[#out_hls + 1] = hls end

  push(table_rule(TBL.TL, TBL.TM, TBL.TR, widths))            -- top rule
  for ri, cells in ipairs(raw_rows) do
    -- Wrap each cell to its capped width; the row spans the tallest cell.
    local wrapped, height = {}, 1
    for c = 1, ncols do
      wrapped[c] = wrap_text(cells[c] or "", widths[c])
      if #wrapped[c] > height then height = #wrapped[c] end
    end
    for k = 1, height do                                      -- one physical line per wrap row
      local segs, hls, blen = {}, {}, 0
      segs[#segs + 1] = TBL.V; hls[#hls + 1] = { blen, blen + #TBL.V, "ClaudeDim" }; blen = blen + #TBL.V
      for c = 1, ncols do
        segs[#segs + 1] = " "; blen = blen + 1
        local clean, ih = parse_inline(wrapped[c][k] or "")
        for _, h in ipairs(ih) do hls[#hls + 1] = { blen + h[1], blen + h[2], h[3] } end
        if ri == 1 then hls[#hls + 1] = { blen, blen + #clean, "ClaudeBold" } end
        segs[#segs + 1] = clean; blen = blen + #clean
        local pad = widths[c] - vim.fn.strdisplaywidth(clean)
        if pad > 0 then segs[#segs + 1] = string.rep(" ", pad); blen = blen + pad end
        segs[#segs + 1] = " "; blen = blen + 1
        segs[#segs + 1] = TBL.V; hls[#hls + 1] = { blen, blen + #TBL.V, "ClaudeDim" }; blen = blen + #TBL.V
      end
      push(table.concat(segs), hls)
    end
    if ri == 1 then push(table_rule(TBL.ML, TBL.MM, TBL.MR, widths)) end  -- header divider
  end
  push(table_rule(TBL.BL, TBL.BM, TBL.BR, widths))            -- bottom rule
  return out_lines, out_hls
end

-- ─── Directory-tree rendering ────────────────────────────────────────────────

-- Folder glyph (nf-fa-folder) prefixed to directory entries in a tree.
local TREE_FOLDER_GLYPH = ""

-- True when a line is part of an ASCII/Unicode directory tree: it either has a
-- box-drawing connector (│ ├ └ ──) OR is a lone path token (a single dir ending
-- "/" or a file with an extension), optionally trailed by a "# comment".
local function is_tree_line(line)
  if line:find("│", 1, true) or line:find("├", 1, true)
      or line:find("└", 1, true) or line:find("──", 1, true) then
    return true
  end
  local body  = line:match("^%s*(.-)%s*$")
  local first = body:match("^(%S+)")
  if not first then return false end
  local after = body:sub(#first + 1):match("^%s*(.-)%s*$")
  local lone  = (after == "" or after:sub(1, 1) == "#")
  return lone and (first:sub(-1) == "/" or first:match("%.%w+$") ~= nil) or false
end

-- Byte index of the end of the box-drawing structure prefix (0 when none).
local function tree_prefix_end(line)
  local pos = 0
  for _, b in ipairs({ "│", "├", "└", "─" }) do
    local s = 1
    while true do
      local a, e = line:find(b, s, true)
      if not a then break end
      if e > pos then pos = e end
      s = e + 1
    end
  end
  return pos
end

-- Render one tree line: dim the box-drawing structure, then colour each entry
-- token — directories (trailing "/") get a folder glyph + ClaudeDir, files get
-- their devicons glyph + language colour (same as everywhere else), a leading
-- "#" comment is dimmed, and anything else stays prose. Returns display, hls.
local function render_tree_line(line)
  local out, hls, blen = {}, {}, 0
  local pend = tree_prefix_end(line)
  if pend > 0 then
    local pref = line:sub(1, pend)
    out[#out + 1] = pref
    hls[#hls + 1] = { 0, #pref, "ClaudeDim" }
    blen = #pref
  end

  local rest = line:sub(pend + 1)
  local idx  = 1
  while idx <= #rest do
    local ws = rest:match("^(%s+)", idx)
    if ws then out[#out + 1] = ws; blen = blen + #ws; idx = idx + #ws end
    if idx > #rest then break end
    local tok = rest:match("^(%S+)", idx)
    if not tok then break end
    idx = idx + #tok

    if tok:sub(1, 1) == "#" then
      -- comment: dim to end of line
      local comment = tok .. rest:sub(idx)
      out[#out + 1] = comment
      hls[#hls + 1] = { blen, blen + #comment, "ClaudeDim" }
      blen = blen + #comment
      idx  = #rest + 1
    elseif #tok > 1 and tok:sub(-1) == "/" then
      local seg = TREE_FOLDER_GLYPH .. " " .. tok
      out[#out + 1] = seg
      hls[#hls + 1] = { blen, blen + #seg, "ClaudeDir" }
      blen = blen + #seg
    else
      local fname = tok:match("([^/]+)$")
      local ext   = fname and fname:match("%.([%w]+)$")
      local icon, hl
      if ext then
        local ok, dev = pcall(require, "nvim-web-devicons")
        if ok then icon, hl = dev.get_icon(fname, ext, { default = false }) end
      end
      if icon and hl then
        local seg = icon .. " " .. tok
        out[#out + 1] = seg
        hls[#hls + 1] = { blen, blen + #seg, hl }
        blen = blen + #seg
      else
        out[#out + 1] = tok
        blen = blen + #tok
      end
    end
  end
  return table.concat(out), hls
end

-- ─── Rich markdown block elements (headings / lists / quotes / rules / code) ──
-- Each predicate classifies one raw line; each renderer returns either a single
-- (display, hls) pair (heading/hrule/quote/list) or, for fenced code, a run of
-- lines built by render_code_block. All highlight byte offsets are 0-indexed
-- start / end-exclusive, matching nvim_buf_add_highlight (same contract as
-- parse_inline / render_table). Colours come from the Claude palette so the
-- rendered markdown stays cohesive with the rest of the panel.

-- Right-pad a string with spaces to a target DISPLAY width (multibyte-safe), so a
-- background highlight paints as a solid rectangle to the panel edge (used for
-- heading bars and code-block panels). Defined up here so render_heading can use
-- it too.
local function pad_display(s, w)
  local pad = w - vim.fn.strdisplaywidth(s)
  return pad > 0 and (s .. string.rep(" ", pad)) or s
end

-- ATX heading: 1–6 leading '#', then a space. (Fenced code is handled before
-- this in build_md_lines, so a '#' inside a code block never reaches here.)
local function is_heading(s) return s:match("^#+%s") ~= nil and #s:match("^(#+)") <= 6 end

-- Horizontal rule: a line of only ---, ***, or ___ (3+), ignoring surrounding
-- space. Table separators (which contain '|') are matched earlier, so this only
-- sees true rules.
local function is_hrule(s)
  local t = s:gsub("%s", "")
  return t:match("^%-%-%-+$") ~= nil or t:match("^%*%*%*+$") ~= nil or t:match("^___+$") ~= nil
end

local function is_quote(s)      return s:match("^%s*>") ~= nil end
local function is_list_item(s)  return s:match("^%s*[%-%*%+]%s") ~= nil or s:match("^%s*%d+[%.%)]%s") ~= nil end
local function is_fence(s)      return s:match("^%s*```") ~= nil end

-- Heading → blue, bold, on a full-width background bar so it reads as a section
-- banner. The literal #/##/### markers are KEPT (per user pref) as the level cue
-- and share the heading colour; only a trailing run of #'s is dropped. The line
-- is padded to panel width so the bg fills the whole row. Heading text is
-- inline-parsed so `code`/**bold** inside a heading still style.
local function render_heading(line)
  local hashes = line:match("^(#+)")
  local prefix = line:match("^(#+%s*)")              -- "# " incl. the space(s)
  local body   = line:gsub("%s*#+%s*$", "")          -- drop optional closing ###
  local rest   = body:sub(#prefix + 1)
  local group  = (#hashes == 1 and "ClaudeH1") or (#hashes == 2 and "ClaudeH2") or "ClaudeH3"
  local clean_rest, ihls = parse_inline(rest)
  local text   = prefix .. clean_rest
  local padded = pad_display(text, math.max(panel_width() - 2, vim.fn.strdisplaywidth(text)))
  local hls    = { { 0, #padded, group } }           -- bg bar + fg over the whole row
  for _, h in ipairs(ihls) do hls[#hls + 1] = { #prefix + h[1], #prefix + h[2], h[3] } end
  return padded, hls
end

-- Horizontal rule → a dim full-width line, sitting just inside the panel edges.
local function render_hrule()
  local w    = math.max(panel_width() - 4, 10)
  local line = string.rep("─", w)
  return line, { { 0, #line, "ClaudeDim" } }
end

-- Blockquote → a clay left bar ("▌") + muted italic body. One '>' level is
-- stripped; deeper nesting just keeps the extra '>' in the (still-quoted) text.
local QUOTE_BAR = "▌ "
local function render_quote(line)
  local body = line:gsub("^%s*>%s?", "")
  local clean, ihls = parse_inline(body)
  local out  = QUOTE_BAR .. clean
  local bar  = #"▌"                                  -- byte length of the bar glyph
  local hls  = { { 0, bar, "ClaudeQuoteBar" }, { #QUOTE_BAR, #out, "ClaudeQuote" } }
  for _, h in ipairs(ihls) do hls[#hls + 1] = { #QUOTE_BAR + h[1], #QUOTE_BAR + h[2], h[3] } end
  return out, hls
end

-- List item → marker replaced by a clay bullet glyph (•/◦ by nesting depth) or,
-- for ordered lists, the original "N." kept but coloured; item text inline-parsed.
local function render_list_item(line)
  local indent, marker, rest = line:match("^(%s*)([%-%*%+])%s+(.*)$")
  if marker then
    local glyph  = (math.floor(#indent / 2) % 2 == 0) and "•" or "◦"
    local clean, ihls = parse_inline(rest)
    local prefix = indent .. glyph .. " "
    local hls    = { { #indent, #indent + #glyph, "ClaudeBullet" } }
    for _, h in ipairs(ihls) do hls[#hls + 1] = { #prefix + h[1], #prefix + h[2], h[3] } end
    return prefix .. clean, hls
  end
  local oindent, num, sep, orest = line:match("^(%s*)(%d+)([%.%)])%s+(.*)$")
  local clean, ihls = parse_inline(orest)
  local prefix = oindent .. num .. sep .. " "
  local hls    = { { #oindent, #oindent + #num + #sep, "ClaudeBullet" } }
  for _, h in ipairs(ihls) do hls[#hls + 1] = { #prefix + h[1], #prefix + h[2], h[3] } end
  return prefix .. clean, hls
end

-- Left gutter for fenced code rows: the clay ▎ bar plus a 3-space inset so code
-- text floats off the bar instead of jamming against it (pad_display is up top).
-- The block bg is painted from the bar's end (not from here), so this whole pad
-- sits inside the recessed panel — see render_code_block.
local CODE_GUTTER = "▎   "

-- Common fenced-language hints → treesitter parser names.
local TS_LANG = {
  js = "javascript", jsx = "javascript", ts = "typescript", tsx = "tsx",
  py = "python", rb = "ruby", sh = "bash", shell = "bash", zsh = "bash",
  yml = "yaml", md = "markdown", rs = "rust", cpp = "cpp", ["c++"] = "cpp",
  golang = "go", h = "c", hpp = "cpp",
}

-- Compute treesitter syntax highlights for a fenced code body. Parses the body
-- AS A STRING (no buffer needed), runs the language's `highlights` query, and
-- Map a treesitter capture name → one of our themed ClaudeCode* groups (which
-- bake in the block bg). Keyed by the TOP-LEVEL capture (so keyword.function,
-- string.escape, comment.todo, punctuation.bracket … collapse onto their
-- family). This covers EVERY colour-bearing family in the standard treesitter
-- highlight set, so real code tokens never fall back to neutral.
--
-- Deliberately NOT mapped: the control captures @spell / @nospell / @conceal /
-- @none. They carry no colour and their ranges OVERLAP @comment/@string — mapping
-- them would repaint comments and strings neutral and destroy those colours. They
-- must stay unmapped so the real colour underneath shows.
local CODE_CAP = {
  -- keywords & control flow
  keyword = "ClaudeCodeKeyword", conditional = "ClaudeCodeKeyword",
  ["repeat"] = "ClaudeCodeKeyword", label = "ClaudeCodeKeyword",
  exception = "ClaudeCodeKeyword", include = "ClaudeCodeKeyword",
  -- operators / punctuation
  operator = "ClaudeCodeOper", punctuation = "ClaudeCodePunc",
  -- literals
  string = "ClaudeCodeString", character = "ClaudeCodeString",
  number = "ClaudeCodeNumber", float = "ClaudeCodeNumber", boolean = "ClaudeCodeNumber",
  -- comments
  comment = "ClaudeCodeComment",
  -- callables
  ["function"] = "ClaudeCodeFunc", method = "ClaudeCodeFunc", constructor = "ClaudeCodeFunc",
  -- types / modules / tags
  type = "ClaudeCodeType", module = "ClaudeCodeType", namespace = "ClaudeCodeType",
  tag = "ClaudeCodeType",
  -- constants / attributes
  constant = "ClaudeCodeConst", attribute = "ClaudeCodeConst",
  -- identifiers
  variable = "ClaudeCodeVar", property = "ClaudeCodeVar",
  field = "ClaudeCodeVar", parameter = "ClaudeCodeVar",
  -- markup / prose / diff (markdown-in-code, legacy @text.*, diff fences)
  markup = "ClaudeCodeVar", text = "ClaudeCodeVar", diff = "ClaudeCodeVar",
  title = "ClaudeCodeKeyword", uri = "ClaudeCodeString", math = "ClaudeCodeNumber",
  environment = "ClaudeCodeType", note = "ClaudeCodeComment", warning = "ClaudeCodeComment",
  danger = "ClaudeCodeComment", todo = "ClaudeCodeComment", error = "ClaudeCodeComment",
}
local function code_group(name)
  return CODE_CAP[name:gsub("%..*$", "")]            -- top-level family only
end

-- Compute treesitter syntax highlights for a fenced code body. Parses the body
-- AS A STRING (no buffer needed), runs the language's `highlights` query, and
-- returns a table keyed by 1-based body-line index → list of {col0, col1, group}
-- (byte columns; group is a themed ClaudeCode* name). Returns nil when no
-- parser/query is available so the caller falls back to the flat neutral block.
-- Fully guarded — a missing parser must never break rendering.
local function code_ts_hls(lang, body)
  if lang == "" then return nil end
  -- nvim-treesitter is lazy-loaded on BufReadPre/BufNewFile (see plugins/treesitter.lua).
  -- When the Claude panel renders a code block before any file buffer has been opened
  -- (dashboard → panel), the plugin hasn't loaded, so its parser/ dir is not on
  -- runtimepath and get_string_parser throws "No parser for language X" → flat code.
  -- Force the plugin to load once so the language parsers are registered. require is
  -- memoised, so this is a no-op after the first call.
  pcall(require, "nvim-treesitter")
  local plang = TS_LANG[lang:lower()] or lang:lower()
  local src   = table.concat(body, "\n")
  local ok, parser = pcall(vim.treesitter.get_string_parser, src, plang)
  if not ok or not parser then return nil end
  local got_q, query = pcall(vim.treesitter.query.get, plang, "highlights")
  if not got_q or not query then return nil end
  local ok_tree, trees = pcall(function() return parser:parse() end)
  if not ok_tree or not trees or not trees[1] then return nil end
  local root = trees[1]:root()

  local by_line = {}
  local function add(row0, c0, c1, group)
    if c1 <= c0 then return end
    local li = row0 + 1
    by_line[li] = by_line[li] or {}
    by_line[li][#by_line[li] + 1] = { c0, c1, group }
  end
  local ok_iter = pcall(function()
    for id, node in query:iter_captures(root, src, 0, -1) do
      local name  = query.captures[id]
      local group = name and code_group(name)
      if group then
        local srow, scol, erow, ecol = node:range()
        if srow == erow then
          add(srow, scol, ecol, group)
        else                                        -- multi-line: first→EOL, mids, last→head
          add(srow, scol, #(body[srow + 1] or ""), group)
          for r = srow + 1, erow - 1 do add(r, 0, #(body[r + 1] or ""), group) end
          add(erow, 0, ecol, group)
        end
      end
    end
  end)
  if not ok_iter then return nil end
  return by_line
end

-- Fenced code block → a recessed panel: a dim italic language label on the top
-- fence row, then each body line behind a clay left gutter, every row padded to
-- panel width so the dark background reads as one block. Body text is NOT
-- inline-parsed (code is literal) but IS syntax-highlighted via treesitter when a
-- parser exists — the @capture spans carry fg only, so the block bg shows through.
-- Returns out_lines, out_hls.
local function render_code_block(lang, body)
  local w = math.max(panel_width() - 2, 20)
  local out_lines, out_hls = {}, {}
  local gutter_b = #"▎"                               -- bar glyph byte length
  local syn = code_ts_hls(lang, body)

  -- Top fence row: gutter + language label (or just the gutter when bare).
  local head = pad_display(CODE_GUTTER .. (lang ~= "" and lang or ""), w)
  out_lines[1] = head
  out_hls[1]   = {
    { 0, gutter_b, "ClaudeCodeGutter" },
    { gutter_b, #head, "ClaudeCodeLang" },             -- bg covers the inset pad too
  }

  -- Content width = panel minus the gutter+inset; code lines wider than this are
  -- HARD-WRAPPED into chunks here (rather than relying on Vim's soft wrap) so EACH
  -- screen row carries its own gutter bar + block bg. A soft-wrapped continuation
  -- row would otherwise show bare (no gutter, no bg) past the block edge.
  local gutter_dw = vim.fn.strdisplaywidth(CODE_GUTTER)
  local cw        = math.max(w - gutter_dw, 1)

  for i, bl in ipairs(body) do
    local spans = syn and syn[i] or nil
    local rest, boff = bl, 0                           -- remaining text, byte offset into bl
    repeat
      local chunk = (rest == "") and "" or disp_take(rest, cw)
      local clen  = #chunk
      local row   = pad_display(CODE_GUTTER .. chunk, w)
      local hls   = {
        { 0, gutter_b, "ClaudeCodeGutter" },
        { gutter_b, #row, "ClaudeCodeBlock" },         -- bg + neutral fg base, covers inset pad
      }
      if spans then                                    -- overlay syntax fg spans, clipped to chunk
        for _, s in ipairs(spans) do
          local sb = s[1]
          local se = math.min(s[2], #bl)
          local cs = math.max(sb, boff)                -- intersect [sb,se) with this chunk's byte span
          local ce = math.min(se, boff + clen)
          if ce > cs then
            hls[#hls + 1] = { #CODE_GUTTER + (cs - boff), #CODE_GUTTER + (ce - boff), s[3] }
          end
        end
      end
      out_lines[#out_lines + 1] = row
      out_hls[#out_hls + 1] = hls
      rest = rest:sub(clen + 1)
      boff = boff + clen
    until rest == ""
  end
  return out_lines, out_hls
end

-- True when a fenced block's body is actually a directory tree (≥2 lines carry
-- box-drawing glyphs). Claude almost always wraps trees in a ``` fence, which
-- would otherwise render as flat code; this reroutes them to the tree renderer.
local function body_is_tree(body)
  local n = 0
  for _, l in ipairs(body) do
    if l:find("├", 1, true) or l:find("└", 1, true)
        or l:find("│", 1, true) or l:find("──", 1, true) then
      n = n + 1
      if n >= 2 then return true end
    end
  end
  return false
end

-- Transform raw markdown lines into rendered display lines + per-line highlight
-- ranges. Dispatch order matters: fenced code first (so its contents are never
-- re-parsed), then tables, then the block elements, then trees, then inline
-- prose. Pure (no buffer writes) so it can be unit-tested directly.
-- Returns clean (display lines), per_line_hls (per-line list of {s0,e,group}).
local function build_md_lines(raw)
  local clean, per_line_hls = {}, {}
  local function push(line, hls) clean[#clean + 1] = line; per_line_hls[#clean] = hls end
  local function push_run(lines, hls_list)
    for k, l in ipairs(lines) do push(l, hls_list[k]) end
  end

  local idx = 1
  while idx <= #raw do
    local line = raw[idx]
    if is_fence(line) then
      -- Collect body up to the closing fence (or end of block). The fence rows
      -- themselves are dropped.
      local lang = line:match("^%s*```%s*(%S*)") or ""
      local body, j = {}, idx + 1
      while j <= #raw and not is_fence(raw[j]) do
        body[#body + 1] = raw[j]; j = j + 1
      end
      if body_is_tree(body) then
        -- Fenced directory tree → render each line with glyphs, not as flat code.
        for _, bl in ipairs(body) do push(render_tree_line(bl)) end
      else
        push_run(render_code_block(lang, body))
      end
      idx = (j <= #raw) and j + 1 or j          -- skip the closing fence if present
    elseif is_table_row(line) then
      local j, rows = idx, {}
      while j <= #raw and is_table_row(raw[j]) do rows[#rows + 1] = raw[j]; j = j + 1 end
      push_run(render_table(rows))
      idx = j
    elseif is_heading(line) then
      push(render_heading(line)); idx = idx + 1
    elseif is_hrule(line) then
      push(render_hrule()); idx = idx + 1
    elseif is_quote(line) then
      push(render_quote(line)); idx = idx + 1
    elseif is_list_item(line) then
      push(render_list_item(line)); idx = idx + 1
    elseif is_tree_line(line) then
      push(render_tree_line(line)); idx = idx + 1
    else
      push(parse_inline(line)); idx = idx + 1
    end
  end
  return clean, per_line_hls
end

-- ─── Exports (only the symbols init.lua calls from outside this module) ────────

Markdown.build_md_lines    = build_md_lines
Markdown.render_table      = render_table
Markdown.render_code_block = render_code_block
Markdown.is_fence          = is_fence
Markdown.wrap_text         = wrap_text
Markdown.disp_take         = disp_take

return Markdown
