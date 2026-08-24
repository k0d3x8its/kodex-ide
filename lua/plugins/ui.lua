-- lua/plugins/ui.lua
return {
	-- Dracula colorscheme (Lua port)
	{
		"Mofiqul/dracula.nvim",
		name = "dracula",
		lazy = false, -- load at startup
		priority = 1000, -- before other plugins
		config = function()
			local dracula = require("dracula")

			dracula.load() -- sets the colorscheme
		end,
	},

	-- Lualine statusline
	{
		"nvim-lualine/lualine.nvim",
		dependencies = { "nvim-tree/nvim-web-devicons" },
		lazy = false,
		config = function()
			local lualine = require("lualine")
			local lazy_status = require("lazy.status")
			local pio_status = require("utils.pio_status")

			pio_status.setup()

			local function lazy_updates_icon()
				local updates = lazy_status.updates()
				if updates == "" then
					return ""
				end
				local count = updates:match("(%d+)")
				return count .. " "
			end

			-- True when the focused buffer is the Claude panel (or its reply float) —
			-- both carry filetype "claude". Drives the modal statusline so the panel
			-- reads as a native Neovim mode: CLAUDE on the left, CODE on the right.
			local function in_claude()
				return vim.bo.filetype == "claude"
			end

			-- Orange (clay #D97757) fill for the modal CLAUDE / CODE words, matching the
			-- Claude logo glyph. Applied only while the panel shows its mode word
			-- ("CLAUDE", i.e. normal mode) — when the chat bar is open and the user is
			-- typing, the mode segment shows a normal "INSERT" in the default theme
			-- colour, exactly like any other Neovim window.
			local claude_orange = { bg = "#D97757", fg = "#111010", gui = "bold" }
			local function mode_color()
				if in_claude() and vim.fn.mode() == "n" then
					return claude_orange
				end
				return nil
			end

			-- Powerline separator glyphs as explicit UTF-8 bytes (U+E0B0 right, U+E0B2
			-- left) so the orange CLAUDE / CODE blocks keep their arrow caps — a custom
			-- component `color` otherwise drops lualine's auto-drawn section separators.
			local pl_right = "\238\130\176"
			local pl_left = "\238\130\178"

			-- Model (left, lualine_b) and session cost (right, lualine_y) must read as
			-- the SAME meta tier in both chat-bar states. Dracula maps b and y to the
			-- lightgray tier, but when the chat bar opens the panel goes inactive and
			-- the model falls into lualine_c (darker gray) while cost stays in y —
			-- giving a mismatch. Pinning both to the explicit b-tier colour locks them
			-- identical, active or inactive.
			local meta_color = { bg = "#5f6a8e", fg = "#f8f8f2" }

			-- Model reads in the SAME clay-on-meta style as the CAVEMAN badge on the right
			-- (bold #D97757 text on the meta bg), so the two accents bookend the tier. The
			-- effort level next to it uses plain meta_color (white text), matching the
			-- session cost. Both sit on the meta bg in BOTH bar states — only CLAUDE/CODE
			-- swap to the dim #44475a block when the bar opens.
			local model_color = { bg = meta_color.bg, fg = "#D97757", gui = "bold" }

			-- Inactive (chat bar open) CLAUDE / CODE: dim the orange block down to the
			-- panel gray #44475a with orange text. Because lualine colours a separator
			-- arrow as fg = block.bg, giving the block a #44475a bg also makes the
			-- powerline arrow glyph #44475a — the cap reads as the same gray, not orange.
			local claude_dim = { bg = "#44475a", fg = "#D97757", gui = "bold" }

			lualine.setup({
				options = {
					theme = "dracula",
					section_separators = { left = "", right = "" },
					component_separators = { left = " ", right = "" },
				},
				sections = {
					-- Mode segment: show "CLAUDE" in the panel in normal mode, but fall back
					-- to the real mode ("INSERT" while typing in the chat float) so the bar
					-- behaves like a native Neovim window when editing.
					lualine_a = {
						{
							"mode",
							color = mode_color,
							-- Explicit right arrow so the orange CLAUDE block keeps its powerline
							-- cap (the custom colour drops the auto separator). Same glyph as
							-- section_separators, so non-claude buffers look unchanged.
							separator = { right = pl_right },
							fmt = function(str)
								if in_claude() and str == "NORMAL" then
									return "CLAUDE"
								end
								return str
							end,
						},
					},
					-- In the panel, show the model (Sonnet 4.6) immediately right of the
					-- CLAUDE word so the mode word points straight at what it's running. Every
					-- other buffer keeps lualine's default B section (branch/diff/diagnostics).
					lualine_b = {
						-- Panel layout: CLAUDE (mode, lualine_a) → model → effort level. The
						-- model name sits right of CLAUDE, then the effort level caps the run
						-- in place of the OS penguin (preview: "CLAUDE  Opus 4.8  high").
						{
							function()
								return require("utils.claude").current_model()
							end,
							cond = in_claude,
							color = model_color,
						},
						-- Effort level (low/medium/high/xhigh/max) right of the model, in place
						-- of the old ✻ sparkle — set via the /effort slider. White-on-meta like
						-- the session cost, so the two read as the same tier.
						{
							function()
								return require("utils.claude").current_effort()
							end,
							cond = in_claude,
							color = meta_color,
							-- Drop the component's own left padding so only the single
							-- component_separator space sits between the model and the level
							-- (default padding stacked on the separator read as a double gap).
							padding = { left = 0, right = 1 },
						},
						-- File format (the OS glyph,  on Linux) for NON-panel windows only —
						-- the panel shows the effort level above instead. Reads naturally
						-- beside the file's identity on the left.
						{
							"fileformat",
							cond = function()
								return not in_claude()
							end,
						},
						{
							"branch",
							cond = function()
								return not in_claude()
							end,
						},
						{
							"diff",
							cond = function()
								return not in_claude()
							end,
						},
						{
							"diagnostics",
							cond = function()
								return not in_claude()
							end,
						},
					},
					lualine_c = {
						-- Hide the buffer name in the panel (it rendered as the redundant,
						-- truncated "claude [-]"); show it normally everywhere else.
						{
							"filename",
							symbols = { unnamed = "[terminal]" },
							cond = function()
								return not in_claude()
							end,
						},
						{
							pio_status.badge,
							padding = { left = 0, right = 0 },
						},
					},
					lualine_x = {
						{
							lazy_updates_icon,
							cond = lazy_status.has_updates,
							color = { fg = "#ff9e64" },
						},
						"encoding",
						-- Drop the "claude" filetype tag in the panel (redundant with the
						-- CLAUDE mode word); keep it for every other buffer.
						{
							"filetype",
							cond = function()
								return not in_claude()
							end,
						},
					},
					-- Panel: this session's cost ($0.42) sits just left of CODE so the CODE
					-- arrow points at it. It's the panel's OWN subprocess cost (mod.session_cost),
					-- not the shared burn-state file. Non-panel buffers keep scroll progress.
					lualine_y = {
						{
							function()
								return require("utils.claude").session_cost()
							end,
							cond = in_claude,
							color = meta_color,
						},
						-- CAVEMAN badge between the cost and CODE — present only while the
						-- caveman plugin is enabled, so the user can see at a glance that the
						-- panel's replies are caveman-compressed. Same bg as the cost block
						-- (meta_color), Claude clay #D97757 text, so it reads as part of the
						-- cost section rather than a new tier.
						{
							function()
								return "CAVEMAN"
							end,
							cond = function()
								return in_claude() and require("utils.claude").caveman_active()
							end,
							color = { bg = meta_color.bg, fg = "#D97757", gui = "bold" },
						},
						{
							"progress",
							cond = function()
								return not in_claude()
							end,
						},
					},
					-- Far-right "CODE" mirrors the left "CLAUDE", same orange fill; only in
					-- the panel. The panel's own line:col isn't useful, so location shows only
					-- for non-panel buffers; in the panel CODE caps the cost/rate segment.
					lualine_z = {
						{
							"location",
							cond = function()
								return not in_claude()
							end,
						},
						{
							function()
								return "CODE"
							end,
							cond = in_claude,
							-- Mirror CLAUDE's color: orange in normal mode, default otherwise
							-- (e.g. when the user visually selects text in the panel).
							color = mode_color,
							-- Left arrow so CODE gets a powerline cap into its orange block.
							separator = { left = pl_left },
						},
					},
				},
				-- Inactive windows (per-window statuslines). While the user types in the
				-- chat float, the panel is "inactive", so without this its bar would fall
				-- back to the default filename → the ugly "claude [-]". Show a clean
				-- "CLAUDE … model/effort … CODE" instead; the filename stays for normal
				-- buffers. Mirror the ACTIVE layout section-for-section so the panel's
				-- bar looks identical whether the chat bar is focused (panel inactive)
				-- or not. The earlier "fg-only, all in lualine_c" inactive layout
				-- dropped the left powerline arrows: an arrow cap needs a coloured
				-- block to terminate, and with CLAUDE/model/effort all in one section
				-- there are no section transitions to draw the right-pointing caps.
				-- Putting CLAUDE in lualine_a (orange block + pl_right) and
				-- model/effort in lualine_b restores both left arrows.
				inactive_sections = {
					lualine_a = {
						{
							function()
								return "CLAUDE"
							end,
							cond = in_claude,
							color = claude_dim,
							separator = { right = pl_right },
						},
					},
					lualine_b = {
						{
							function()
								return require("utils.claude").current_model()
							end,
							cond = in_claude,
							color = model_color,
						},
						-- Effort level (was the ✻ sparkle) stays on the meta bg beside the model
						-- when the bar is open — same tier as cost/CAVEMAN. Only CLAUDE/CODE swap
						-- to the dim #44475a block; model+effort read as one continuous meta run,
						-- so no dark powerline arrow is drawn between them (like cost+CAVEMAN).
						{
							function()
								return require("utils.claude").current_effort()
							end,
							cond = in_claude,
							color = meta_color,
							padding = { left = 0, right = 1 },
						},
					},
					lualine_c = {
						{
							"filename",
							cond = function()
								return not in_claude()
							end,
						},
						{ pio_status.badge, padding = { left = 0, right = 0 } },
					},
					lualine_x = {
						{
							"location",
							cond = function()
								return not in_claude()
							end,
						},
					},
					-- Session cost sits right next to CODE so its arrow caps the cost segment,
					-- mirroring the CLAUDE → model arrow on the left.
					lualine_y = {
						{
							function()
								return require("utils.claude").session_cost()
							end,
							cond = in_claude,
							color = meta_color,
						},
						-- Same CAVEMAN badge as the active layout, so the chat-bar-open state
						-- shows it identically.
						{
							function()
								return "CAVEMAN"
							end,
							cond = function()
								return in_claude() and require("utils.claude").caveman_active()
							end,
							color = { bg = meta_color.bg, fg = "#D97757", gui = "bold" },
						},
					},
					lualine_z = {
						{
							function()
								return "CODE"
							end,
							cond = in_claude,
							color = claude_dim,
							separator = { left = pl_left },
						},
					},
				},
			})
		end,
	},
}
