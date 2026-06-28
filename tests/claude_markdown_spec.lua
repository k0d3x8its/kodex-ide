-- tests/claude_markdown_spec.lua
-- Exercises the pure markdown transformer claude._build_md_lines (and the
-- box-table renderer claude._render_table) for the rich-render batch: headings,
-- horizontal rules, blockquotes, lists, fenced code blocks, and box-drawn
-- tables. These are pure functions (no buffer writes), so the spec inspects the
-- returned (clean_lines, per_line_hls) directly — no panel/window needed.
-- Run: nvim --headless -u NONE --cmd "set runtimepath+=." -c "luafile tests/claude_markdown_spec.lua"

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

-- True when any highlight range in `hls` uses group `g`.
local function has_group(hls, g)
  for _, h in ipairs(hls) do if h[3] == g then return true end end
  return false
end

-- Convenience: transform one markdown string into (clean, hls) line arrays.
local function md(str)
  return claude._build_md_lines(vim.split(str, "\n", { plain = true }))
end

-- ── Headings (# markers KEPT as the level cue; padded to a full-width bar) ──
local c, hl = md("# Title")
H.check("H1: # marker kept", c[1]:match("^# Title") ~= nil, c[1])
H.check("H1: padded to a bar (trailing space)", #c[1] > #"# Title")
H.check("H1: ClaudeH1 over line", has_group(hl[1], "ClaudeH1"))

c, hl = md("## Sub")
H.check("H2: ## marker kept + ClaudeH2", c[1]:match("^## Sub") ~= nil and has_group(hl[1], "ClaudeH2"))

c, hl = md("### Deep ###")
H.check("H3: closing hashes dropped, leading kept", vim.trim(c[1]) == "### Deep", c[1])
H.check("H3: ClaudeH3", has_group(hl[1], "ClaudeH3"))

c, hl = md("## `cfg.lua` patched")
H.check("Heading keeps inline code span", has_group(hl[1], "DevIconLua") or has_group(hl[1], "ClaudeCode"))

-- ── Horizontal rule ─────────────────────────────────────────────────────────
c, hl = md("---")
H.check("HRule: all em-dashes", (c[1]:gsub("─", "")) == "" and #c[1] > 0, c[1])
H.check("HRule: dim", has_group(hl[1], "ClaudeDim"))
c = md("***")
H.check("HRule: *** form", (c[1]:gsub("─", "")) == "")

-- ── Blockquote ──────────────────────────────────────────────────────────────
c, hl = md("> quoted text")
H.check("Quote: bar prefix", c[1]:sub(1, #"▌") == "▌", c[1])
H.check("Quote: text retained", c[1]:find("quoted text", 1, true) ~= nil)
H.check("Quote: bar + body groups", has_group(hl[1], "ClaudeQuoteBar") and has_group(hl[1], "ClaudeQuote"))

-- ── Lists ───────────────────────────────────────────────────────────────────
c, hl = md("- first")
H.check("List(unordered): bullet glyph", c[1] == "• first", c[1])
H.check("List(unordered): ClaudeBullet", has_group(hl[1], "ClaudeBullet"))

c, hl = md("  - nested")
H.check("List(nested): hollow bullet", c[1] == "  ◦ nested", c[1])

c, hl = md("1. one")
H.check("List(ordered): number kept", c[1] == "1. one", c[1])
H.check("List(ordered): ClaudeBullet on marker", has_group(hl[1], "ClaudeBullet"))

-- ── Fenced code block ───────────────────────────────────────────────────────
c, hl = md("```lua\nprint(1)\n**not bold**\n```")
H.check("Code: 2 output rows (lang head + 2 body)", #c == 3, "got " .. #c)
H.check("Code: gutter on every row", c[1]:sub(1, #"▎") == "▎" and c[2]:sub(1, #"▎") == "▎")
H.check("Code: lang label present", c[1]:find("lua", 1, true) ~= nil, c[1])
H.check("Code: body literal (markers NOT parsed)", c[3]:find("**not bold**", 1, true) ~= nil, c[3])
H.check("Code: fence rows dropped", c[2]:find("```", 1, true) == nil)
H.check("Code: ClaudeCodeBlock bg group", has_group(hl[2], "ClaudeCodeBlock"))
H.check("Code: gutter group", has_group(hl[1], "ClaudeCodeGutter"))
-- Padded to a solid block (display width uniform across rows).
H.check("Code: rows padded to common width",
  vim.fn.strdisplaywidth(c[1]) == vim.fn.strdisplaywidth(c[2]),
  vim.fn.strdisplaywidth(c[1]) .. " vs " .. vim.fn.strdisplaywidth(c[2]))

-- ── Fenced directory tree → glyphed tree, not flat code ─────────────────────
c, hl = md("```\nmyproj/\n├── lua/\n│   └── init.lua\n└── README.md\n```")
H.check("Fenced tree: NOT a code block (no gutter ▎)", c[1]:sub(1, #"▎") ~= "▎", c[1])
H.check("Fenced tree: dir gets folder glyph + ClaudeDir",
  has_group(hl[1], "ClaudeDir") or has_group(hl[2], "ClaudeDir"))
H.check("Fenced tree: structure dimmed", (function()
  for _, h in ipairs(hl) do for _, x in ipairs(h) do if x[3] == "ClaudeDim" then return true end end end
end)())

-- ── Code block: treesitter syntax highlighting (when lua parser available) ──
c, hl = md('```lua\nlocal x = "hi"  -- c\n```')
local function any_syntax_group(hls_list)
  for _, line in ipairs(hls_list) do
    for _, h in ipairs(line) do
      if type(h[3]) == "string" and h[3]:match("^ClaudeCode%u")
          and h[3] ~= "ClaudeCodeBlock" and h[3] ~= "ClaudeCodeGutter"
          and h[3] ~= "ClaudeCodeLang" then
        return h[3]
      end
    end
  end
  return nil
end
local has_lua_parser = pcall(vim.treesitter.get_string_parser, "local x = 1", "lua")
if has_lua_parser then
  H.check("Code: lua body syntax-highlighted (themed ClaudeCode* span present)",
    any_syntax_group(hl) ~= nil, tostring(any_syntax_group(hl)))
else
  print("SKIP  Code: lua treesitter parser unavailable in this env")
end
-- Base block bg still present regardless of syntax availability.
H.check("Code: block bg retained alongside syntax", has_group(hl[2], "ClaudeCodeBlock"))

-- ── Box table ───────────────────────────────────────────────────────────────
c, hl = md("| Col | Val |\n|-----|-----|\n| a | 1 |\n| b | 2 |")
H.check("Table: top rule ┌…┐", c[1]:sub(1, #"┌") == "┌" and c[1]:sub(-#"┐") == "┐", c[1])
H.check("Table: header divider ├", c[3]:sub(1, #"├") == "├", c[3])
H.check("Table: bottom rule └…┘", c[#c]:sub(1, #"└") == "└" and c[#c]:sub(-#"┘") == "┘", c[#c])
H.check("Table: header bold", has_group(hl[2], "ClaudeBold"))
H.check("Table: side borders dim", has_group(hl[2], "ClaudeDim"))
-- 1 top + header + divider + 2 body + bottom = 6 lines; |---| row dropped.
H.check("Table: row count (frame + 3 data)", #c == 6, "got " .. #c)
H.check("Table: cell values present", c[4]:find("a", 1, true) and c[5]:find("b", 1, true))

-- ── Wide table fits the panel (overflow would hard-wrap + shatter the box) ──
c = md("| Name | Type | Note |\n|---|---|---|\n| CLAUDE.md | Config | Global standing instructions and conventions here |\n| KNOWLEDGE.md | Reference | Empirical facts |")
local maxw = 0
for _, l in ipairs(c) do maxw = math.max(maxw, vim.fn.strdisplaywidth(l)) end
H.check("Wide table: every line fits panel width", maxw <= math.floor(vim.o.columns * 0.40), "maxw=" .. maxw)
H.check("Wide table: long cell wrapped to extra rows", #c > 6, "got " .. #c)
H.check("Wide table: frame intact (top ┌ / bottom ┘)",
  c[1]:sub(1, #"┌") == "┌" and c[#c]:sub(-#"┘") == "┘")

-- ── Mixed document still flows ──────────────────────────────────────────────
c = md("# Heading\n\nSome **bold** prose.\n\n- item one\n\n> a quote")
H.check("Mixed: heading + list + quote all rendered",
  vim.trim(c[1]) == "# Heading"
    and (function() for _, l in ipairs(c) do if l == "• item one" then return true end end end)()
    and (function() for _, l in ipairs(c) do if l:find("a quote", 1, true) then return true end end end)())

H.summary("claude_markdown")
