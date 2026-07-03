-- lua/plugins/claude.lua
-- Claude Code panel — lazy.nvim plugin spec.
--
-- Anchor: stevearc/dressing.nvim (claude panel uses vim.ui.input, which
-- dressing.nvim styles — a genuine dependency). lazy.nvim merges specs for
-- the same plugin; dressing.lua uses `opts = {}` (auto-generated config), so
-- we MUST NOT add a `config` key here — it would shadow dressing's setup().
-- All initialisation goes in `init` instead.
--
-- No VimEnter hook here — dock.lua owns the single VimEnter for both launchers
-- (FINDINGS.md § A2). Adding a second VimEnter on the same plugin would fire
-- the project picker twice.
--
-- No toggleterm dependency — the Claude panel is a jobstart scratch buffer,
-- not a TUI in toggleterm (FINDINGS.md § D1 / neo-claude.md §6).

return {
  "stevearc/dressing.nvim",

  init = function()
    -- Wire up the Claude panel config before any keymap fires.
    require("utils.claude").setup({ width_pct = 0.40 })

    -- ── Highlight groups ──────────────────────────────────────────────────────
    --
    -- Inline here (not in utils/claude.lua setup()) so the groups live with the
    -- plugin spec that owns the UX — and not in the engine module that is
    -- reusable across projects.
    --
    -- Palette source: kos-capture/screens/ingest.py + neo-claude.md §6 D7.
    -- Over Dracula base; groups must survive colorscheme reloads (see autocmd).

    local function define_highlights()
      -- Clay #D97757 — Claude logo glyph, separator lines, diff-add background.
      -- Bold on the header so the logo glyph renders at full weight in the panel.
      vim.api.nvim_set_hl(0, "ClaudeHeader",  { fg = "#D97757", bold = true })

      -- Light orange #F4A261 — main prose text and result lines.
      -- Matches the "Claude prose" color from ingest.py _fmt_ingest_line.
      vim.api.nvim_set_hl(0, "ClaudeProse",   { fg = "#F4A261" })
      vim.api.nvim_set_hl(0, "ClaudeResult",  { fg = "#F4A261" })

      -- Purple #C084FC — thinking block body (dim), fold headers, tool lines.
      -- Three separate groups so callers can vary boldness/dimming independently
      -- without hardcoding attributes in the render functions.
      vim.api.nvim_set_hl(0, "ClaudeThink",   { fg = "#C084FC" })
      vim.api.nvim_set_hl(0, "ClaudeLabel",   { fg = "#C084FC", bold = true })
      vim.api.nvim_set_hl(0, "ClaudeTool",    { fg = "#C084FC" })
      -- Per-verb tool-line colours so the action reads at a glance instead of
      -- blending into the purple thinking/fold lines. Reading (passive inspect)
      -- in cyan, Running (active execute) in green; other verbs fall back to the
      -- purple ClaudeTool. Resolved by render_tool via TOOL_HL.
      vim.api.nvim_set_hl(0, "ClaudeToolRead", { fg = "#56B6C2" })
      vim.api.nvim_set_hl(0, "ClaudeToolRun",  { fg = "#D19A66" })

      -- Inline markdown: code spans (`...`) in Dracula cyan, bold (**...**) in
      -- white-bold so they pop against the orange ClaudeProse base. Applied by
      -- render_prose after hl_lines(), so these ranges override the base colour.
      vim.api.nvim_set_hl(0, "ClaudeCode",    { fg = "#8BE9FD" })
      vim.api.nvim_set_hl(0, "ClaudeBold",    { fg = "#F8F8F2", bold = true })

      -- Darker, more saturated burnt orange (bold) for lines Claude poses as a
      -- question — pops out of the pale ClaudeProse orange so prompts to the user
      -- are easy to spot. Deliberately deeper than the clay header (#D97757).
      vim.api.nvim_set_hl(0, "ClaudeQuestion", { fg = "#D9531E", bold = true })

      -- Failed tool_result bodies (is_error:true) — Dracula red, clearly an error
      -- and distinct from the burnt-orange ClaudeQuestion prompt colour.
      vim.api.nvim_set_hl(0, "ClaudeError",    { fg = "#FF5555" })

      -- Bracketed spans ([VERIFY], [link]) — Dracula pink so they read clearly
      -- apart from the teal code colour.
      vim.api.nvim_set_hl(0, "ClaudeBracket",  { fg = "#FF79C6" })

      -- Directory entries in rendered trees — folder blue, bold, distinct from
      -- the per-file devicons colours and the green inline paths.
      vim.api.nvim_set_hl(0, "ClaudeDir",      { fg = "#7AA2F7", bold = true })

      -- ── Rich markdown block elements (headings / lists / quotes / code) ────
      -- Headings — blue (#82AAFF) bold on a dark blue-slate background BAR (the
      -- renderer pads the line to panel width so the bg fills the row, reading as a
      -- section banner). Level is shown by the literal #/##/### markers, which the
      -- renderer KEEPS (per user pref), so the three groups share styling and the
      -- hash count is the hierarchy cue.
      vim.api.nvim_set_hl(0, "ClaudeH1", { fg = "#82AAFF", bg = "#2B3145", bold = true })
      vim.api.nvim_set_hl(0, "ClaudeH2", { fg = "#82AAFF", bg = "#2B3145", bold = true })
      vim.api.nvim_set_hl(0, "ClaudeH3", { fg = "#82AAFF", bg = "#2B3145", bold = true })

      -- List bullet glyph — clay, so the marker pops while the item text stays
      -- in the standard ClaudeProse orange. Only the glyph is recoloured.
      vim.api.nvim_set_hl(0, "ClaudeBullet", { fg = "#D97757", bold = true })

      -- Blockquote — a clay left bar with muted, italic body text so quoted
      -- passages recede from the main prose without going invisible.
      vim.api.nvim_set_hl(0, "ClaudeQuoteBar", { fg = "#D97757" })
      vim.api.nvim_set_hl(0, "ClaudeQuote",    { fg = "#9AA0B5", italic = true })

      -- Fenced code block — a recessed panel (Dracula's darker bg #21222C,
      -- below the CursorLine gray the panel uses) with neutral light text, a
      -- clay left gutter bar, and a dim italic language label on the fence row.
      vim.api.nvim_set_hl(0, "ClaudeCodeBlock",  { fg = "#F8F8F2", bg = "#21222C" })
      vim.api.nvim_set_hl(0, "ClaudeCodeGutter", { fg = "#D97757", bg = "#21222C" })
      vim.api.nvim_set_hl(0, "ClaudeCodeLang",   { fg = "#6272A4", bg = "#21222C", italic = true })

      -- Code-block SYNTAX colours (Dracula-family fg on the SAME #21222C panel bg
      -- baked in, so a token never loses the block background). The treesitter
      -- highlighter (utils/claude.lua code_ts_hls) maps captures onto these, so we
      -- don't depend on the colorscheme's @capture links resolving on a non-code
      -- buffer. Unmapped captures fall through to ClaudeCodeBlock (neutral).
      local cbg = "#21222C"
      vim.api.nvim_set_hl(0, "ClaudeCodeKeyword", { fg = "#FF79C6", bg = cbg })             -- keywords/conditionals
      vim.api.nvim_set_hl(0, "ClaudeCodeString",  { fg = "#F1FA8C", bg = cbg })             -- strings/chars
      vim.api.nvim_set_hl(0, "ClaudeCodeComment", { fg = "#6272A4", bg = cbg, italic = true }) -- comments
      vim.api.nvim_set_hl(0, "ClaudeCodeFunc",    { fg = "#50FA7B", bg = cbg })             -- functions/methods
      vim.api.nvim_set_hl(0, "ClaudeCodeNumber",  { fg = "#BD93F9", bg = cbg })             -- numbers/booleans
      vim.api.nvim_set_hl(0, "ClaudeCodeType",    { fg = "#8BE9FD", bg = cbg })             -- types
      vim.api.nvim_set_hl(0, "ClaudeCodeConst",   { fg = "#BD93F9", bg = cbg })             -- constants
      vim.api.nvim_set_hl(0, "ClaudeCodeOper",    { fg = "#FF79C6", bg = cbg })             -- operators
      vim.api.nvim_set_hl(0, "ClaudeCodePunc",    { fg = "#A6ACCD", bg = cbg })             -- punctuation
      vim.api.nvim_set_hl(0, "ClaudeCodeVar",     { fg = "#F8F8F2", bg = cbg })             -- variables/fields

      -- Plan mode accent — blue. Recolours the input bar border/title when the
      -- panel is in --permission-mode plan, signalling no edits will be applied.
      vim.api.nvim_set_hl(0, "ClaudePlan",     { fg = "#61AFEF", bold = true })

      -- Shaded/dim for type-ahead messages queued while Claude is working. They
      -- show muted + italic until the turn ends and they send in the normal user
      -- colour (ClaudeUser).
      vim.api.nvim_set_hl(0, "ClaudeQueued",   { fg = "#6272A4", italic = true })

      -- Gray italic — the "Working…" virtual-text hint at panel bottom.
      -- Intentionally muted so it does not compete with rendered content above.
      vim.api.nvim_set_hl(0, "ClaudeInput",   { fg = "#6272a4", italic = true })

      -- Terminal green — the "❯" prompt arrow in the input bar and the user
      -- message echo, so the panel reads like a shell prompt.
      vim.api.nvim_set_hl(0, "ClaudeArrow",   { fg = "#5AF78E", bold = true })

      -- User message echo text (distinct from Claude's prose).
      vim.api.nvim_set_hl(0, "ClaudeUser",    { fg = "#F8F8F2" })

      -- Banner sidebar lines, each a distinct colour (KOS-style multi-colour):
      --   model line  — soft blue,  path line — green,  version — dim gray.
      vim.api.nvim_set_hl(0, "ClaudeModel",   { fg = "#7FB4CA" })
      vim.api.nvim_set_hl(0, "ClaudePath",    { fg = "#A3BE8C" })
      vim.api.nvim_set_hl(0, "ClaudeDim",     { fg = "#6272a4" })

      -- Panel window background. Shares the chat bar's gray (CursorLine-derived
      -- ClaudeBarBg, computed below) so the whole Claude column — output panel,
      -- bottom-pad rows, and chat bar — reads as ONE flush surface instead of a
      -- gray bar floating over a near-black panel. (Was the KOS Burn Bar near-black
      -- #111010, which left a visible seam at the bar.) bar_bg is resolved here so
      -- ClaudeNormal and ClaudeBarBg can't drift apart.
      local cl     = vim.api.nvim_get_hl(0, { name = "CursorLine" })
      local bar_bg = (cl and cl.bg) or 0x44475a
      vim.api.nvim_set_hl(0, "ClaudeNormal",  { bg = bar_bg })

      -- Invisible cursor: a thin vertical bar (guicursor a:ver1-ClaudeCursorHidden)
      -- coloured to match the panel surface. A 1%-width bar in the bg colour is
      -- invisible AND — unlike a block — does not repaint the glyph cell, so the
      -- character under the cursor (e.g. a fold's ▼/▶ arrow) keeps its own colour.
      -- (blend=100 isn't honoured for the cursor in this terminal; a bg-coloured
      -- BLOCK hid the cursor but blanked the glyph beneath it.) Applied while the
      -- panel is focused; cleared to the real cursor when the chat bar opens.
      local hex_bg = string.format("#%06x", bar_bg)
      vim.api.nvim_set_hl(0, "ClaudeCursorHidden", { fg = hex_bg, bg = hex_bg, nocombine = true })

      -- Clay background — diff-add color in the [Claude proposed] scratch buffer.
      -- Reuses the header clay so the diff palette is consistent with the panel.
      vim.api.nvim_set_hl(0, "ClaudeDiffAdd", { bg = "#D97757" })

      -- ── Review diff: per-window red/green colour lenses ───────────────────
      -- Native `diffthis` is SYMMETRIC: a line unique to the LEFT (removed) and
      -- a line unique to the RIGHT (added) BOTH render under `DiffAdd`, because
      -- vim has no notion of "left = old, right = new". Editing the GLOBAL Diff*
      -- groups would therefore colour both panes identically. The fix is two
      -- highlight NAMESPACES applied per-window (claude_diff.open_diff calls
      -- nvim_win_set_hl_ns): the orig/left window reads Diff* as RED (its unique
      -- lines are removals), the proposed/right window reads them as GREEN (its
      -- unique lines are additions). Same diff, two lenses → red removed / green
      -- added in a side-by-side view. Dracula only ships fg for these groups, so
      -- removed/changed text had no background and read as plain text — this is
      -- what the user saw as "only additions show". (Custom-namespace highlights
      -- are NOT reset by :colorscheme, but we set them inside define_highlights
      -- anyway so the palette lives in one place; create is idempotent by name.)
      local claude = require("utils.claude")
      local del_ns = vim.api.nvim_create_namespace("ClaudeDiffDelLens")
      local add_ns = vim.api.nvim_create_namespace("ClaudeDiffAddLens")
      claude.state.diff_del_ns = del_ns
      claude.state.diff_add_ns = add_ns
      -- LEFT lens (orig): unique lines = REMOVED. DiffText (exact changed chars)
      -- is the brightest red so an intra-line edit pops out of its changed line.
      vim.api.nvim_set_hl(del_ns, "DiffAdd",    { bg = "#5a2b3a" })              -- removed whole line
      vim.api.nvim_set_hl(del_ns, "DiffChange", { bg = "#3a222b" })              -- changed line (old side)
      vim.api.nvim_set_hl(del_ns, "DiffText",   { bg = "#803347", bold = true }) -- exact removed chars
      vim.api.nvim_set_hl(del_ns, "DiffDelete", { fg = "#6272a4" })              -- filler dashes: dim, not red
      -- RIGHT lens (proposed): unique lines = ADDED.
      vim.api.nvim_set_hl(add_ns, "DiffAdd",    { bg = "#2d4d36" })              -- added whole line
      vim.api.nvim_set_hl(add_ns, "DiffChange", { bg = "#22331f" })              -- changed line (new side)
      vim.api.nvim_set_hl(add_ns, "DiffText",   { bg = "#2f6b3e", bold = true }) -- exact added chars
      vim.api.nvim_set_hl(add_ns, "DiffDelete", { fg = "#6272a4" })              -- filler dashes: dim

      -- ── Burn-bar meters (panel winbar: 5h block + weekly limit) ───────────
      -- Reads ~/.claude/kos-burn-bar-state.json (utils/claude_burn.lua). The
      -- filled run is coloured by severity (green→amber→red as usage climbs);
      -- the label, empty track, and reset countdown stay dim so the fill pops.
      vim.api.nvim_set_hl(0, "ClaudeBurnLabel", { fg = "#6272a4" })            -- "5h"/"7d", pct
      vim.api.nvim_set_hl(0, "ClaudeBurnTrack", { fg = "#3b3b52" })            -- ░ empty + ▕▏ brackets
      vim.api.nvim_set_hl(0, "ClaudeBurnReset", { fg = "#6272a4", italic = true }) -- ↻ countdown
      vim.api.nvim_set_hl(0, "ClaudeBurnOk",    { fg = "#A3BE8C", bold = true })   -- < 60% green
      vim.api.nvim_set_hl(0, "ClaudeBurnWarn",  { fg = "#F4A261", bold = true })   -- 60–85% amber
      vim.api.nvim_set_hl(0, "ClaudeBurnCrit",  { fg = "#D9531E", bold = true })   -- ≥ 85% red

      -- ── Chat-bar flush surface (meters drawn inside the rounded box) ───────
      -- The chat float's interior AND border share one gray so the whole bar —
      -- input row + meters row + rounded outline — reads as a single solid
      -- surface "flush" with the panel, not a box floating over it. The user
      -- identified that gray as the one "seen behind the orange line at the top
      -- and surrounding the chat bar": Neovim's CursorLine (cursorline=true in
      -- options.lua). bar_bg was resolved up top (shared with ClaudeNormal) from
      -- the live CursorLine bg so it tracks the theme.
      vim.api.nvim_set_hl(0, "ClaudeBarBg",         { bg = bar_bg })
      -- Border: clay (default) / plan-blue, on the same gray so the outline is
      -- the only thing that pops — the fill blends into the surface.
      vim.api.nvim_set_hl(0, "ClaudeBarBorder",     { fg = "#D97757", bg = bar_bg })
      vim.api.nvim_set_hl(0, "ClaudeBarBorderPlan", { fg = "#61AFEF", bg = bar_bg })
      -- Permission card outline: amber/caution, deliberately distinct from the
      -- clay chat-bar border so the card never reads as the reply input.
      vim.api.nvim_set_hl(0, "ClaudePermBorder",    { fg = "#E5C07B", bg = bar_bg, bold = true })
    end

    define_highlights()

    -- Re-apply after any colorscheme change (`:colorscheme X` resets all
    -- user-defined highlights; without this autocmd the panel goes grey).
    vim.api.nvim_create_autocmd("ColorScheme", {
      group    = vim.api.nvim_create_augroup("ClaudeHighlights", { clear = true }),
      callback = define_highlights,
    })

    -- Right-click "Ask Claude" on a visual selection, at the TOP of the PopUp
    -- menu (above Cut/Copy/Paste). vnoremenu = shown only in visual mode (when
    -- text is highlighted); the default mousemodel "popup_setpos" keeps the
    -- selection when the click lands inside it, so ask_selection reads '<,'>.
    -- The 1.x priority prefixes force it above the default entries (~500); a
    -- separator sits just below it. Registered in init (runs at startup) so the
    -- menu exists before the panel's keys lazy-load.
    vim.cmd([[
      vnoremenu 1.10 PopUp.Ask\ Claude  <Cmd>lua require('utils.claude').ask_selection()<CR>
      vnoremenu 1.20 PopUp.-ClaudeSep-  <Nop>
    ]])
  end,

  keys = {
    {
      "<leader>cc",
      function()
        local claude = require("utils.claude")
        claude.toggle()
        -- Auto-open the reply float when the panel just opened so the user
        -- does not have to press a second key to start typing.
        -- vim.schedule: let toggle()'s autocmds and UI redraws settle first
        -- so the float is positioned against the final window layout.
        if claude.state.claude_active then
          vim.schedule(function() claude.prompt_input() end)
        end
      end,
      desc = "Claude: toggle panel",
    },
    {
      "<leader>cr",
      function() require("utils.claude").reset() end,
      desc = "Claude: reset session",
    },
    {
      "<leader>cm",
      function() require("utils.claude").pick_model() end,
      desc = "Claude: pick model",
    },
    {
      "<leader>cp",
      function() require("utils.claude").toggle_plan() end,
      desc = "Claude: toggle Plan mode",
    },
    {
      -- Toggle open-buffer awareness: when ON, the panel silently attaches the
      -- file you have open (@-mention) to your first message. Persisted across
      -- Kodex IDE restarts. c=claude, b=buffer.
      "<leader>cb",
      function() require("utils.claude").toggle_host_ctx() end,
      desc = "Claude: toggle open-buffer context",
    },
    {
      -- Visual-mode only: yank selection, prompt for a question, send both to
      -- the Claude panel. <leader>cq — c=claude, q=question (mirrors <leader>oq).
      "<leader>cq",
      function() require("utils.claude").ask_selection() end,
      mode = "v",
      desc = "Claude: ask about selection",
    },
  },
}
