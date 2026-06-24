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

      -- Inline markdown: code spans (`...`) in Dracula cyan, bold (**...**) in
      -- white-bold so they pop against the orange ClaudeProse base. Applied by
      -- render_prose after hl_lines(), so these ranges override the base colour.
      vim.api.nvim_set_hl(0, "ClaudeCode",    { fg = "#8BE9FD" })
      vim.api.nvim_set_hl(0, "ClaudeBold",    { fg = "#F8F8F2", bold = true })

      -- Darker, more saturated burnt orange (bold) for lines Claude poses as a
      -- question — pops out of the pale ClaudeProse orange so prompts to the user
      -- are easy to spot. Deliberately deeper than the clay header (#D97757).
      vim.api.nvim_set_hl(0, "ClaudeQuestion", { fg = "#D9531E", bold = true })

      -- Bracketed spans ([VERIFY], [link]) — Dracula pink so they read clearly
      -- apart from the teal code colour.
      vim.api.nvim_set_hl(0, "ClaudeBracket",  { fg = "#FF79C6" })

      -- Directory entries in rendered trees — folder blue, bold, distinct from
      -- the per-file devicons colours and the green inline paths.
      vim.api.nvim_set_hl(0, "ClaudeDir",      { fg = "#7AA2F7", bold = true })

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

      -- Clay background — diff-add color in the [Claude proposed] scratch buffer.
      -- Reuses the header clay so the diff palette is consistent with the panel.
      vim.api.nvim_set_hl(0, "ClaudeDiffAdd", { bg = "#D97757" })

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
    end

    define_highlights()

    -- Re-apply after any colorscheme change (`:colorscheme X` resets all
    -- user-defined highlights; without this autocmd the panel goes grey).
    vim.api.nvim_create_autocmd("ColorScheme", {
      group    = vim.api.nvim_create_augroup("ClaudeHighlights", { clear = true }),
      callback = define_highlights,
    })
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
      -- Visual-mode only: yank selection, prompt for a question, send both to
      -- the Claude panel. <leader>cq — c=claude, q=question (mirrors <leader>oq).
      "<leader>cq",
      function() require("utils.claude").ask_selection() end,
      mode = "v",
      desc = "Claude: ask about selection",
    },
  },
}
