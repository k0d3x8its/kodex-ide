# Changelog

## v1.0.0b (2025-10-30)

- **➕:** PlatformIO
- **➕:** PlatformIO support to keymaps
- **➕:** PlatformIO status in Lualine section C
- **⬆️:** LSP configuration to support PlatformIO filetypes
- **➕:** PlatformIO support to ToggleTerm
- **➕:** PlatformIO status to Lualine UI

## v0.9.9a (2025-10-30)

- **🐞:** causing Live Preview to not be visible in Leader menu
- **🛠️:** bug causing Live Preview to not be visible in Leader menu

## v0.9.8a (2025-10-29)

- **🐞:** causing auto-session to be suppressed
- **🛠️:** bug causing auto-session to be suppressed

## v0.9.7a (2025-10-28)

- **🐞:** causing auto-session to crash
- **🛠️:** bug causing auto-session to crash

## v0.9.6a (2025-10-21)

- **🐞:** causing live-preview to crash
- **🛠️:** bug causing live-preview to crash

## v0.9.5a (2025-10-19)

- **⬆️:** LSP configuration to reflect format provided by developers

## v0.9.4a (2025-09-08)

- **🚀:** dashboard footer to be properly centered

## v0.9.3a (2025-09-02)

- **❌:** unwanted comment
- **🚀:** some keymappyings to be more relevant

## v0.9.2a (2025-08-29)

- **🛠️:** Live Preview from crashing

## v0.9.1a (2025-08-24)

- **🐞:** causes Live Preview to crash when enacting a server
- **➕:** README.md
- **⬆️:** lockfile

## v0.9.1a (2025-08-19)

- **🛠️:** logical error for auto-session to occur properly
- **⬆️:** lockfile

## v0.9.0a (2025-08-19)

- **➕:** regex
- **❌:** warnings in the health check, for Lazy, with the filter
- **➕:** health_filter to core module

## v0.8.0a (2025-08-16)

- **➕:** YAML to mason.lua
- **➕:** YAML to treesitter.lua
- **➕:** YAML to lspconfig.lua
- **➕:** YAML to ale.lua
- **➕:** SchemaStore.nvim for LSP file operations
- **⬆️:** lockfile

## v0.7.0a (2025-08-15)

- **🛠️:** NOTE to have more clarity
- **🚀:** of which-key UI with groups and icons
- **➕:** keymappings for which-key
- **➕:** which-key.nvim
- **⬆️:** comments
- **➕:** customer formatting for Markdown files
- **⬆️:** lockfile

## v0.6.0a (2025-08-15)

- **🚀:** keymaps
- **🚀:** opts in keymaps.lua
- **➕:** Markdown for for documentation purposes
- **⬆️:** lockfile
- **➕:** live-preview for HTML/Markdown

## v0.5.1a (2025-08-10)

- **🛠️:** comments and descriptions for different keymaps
- **🛠️:** depreciated syntax

## v0.5.0a (2025-08-10)

- **♻️:** NOTE to TODO in alpha.lua for Projects section
- **❌:** Perl & Ruby in the Lazy health check
- **⚠️:** syntax
- **🚀:** auto-session to start as soon as Neovim opens
- **❌:** `event = 'VimEnter'`
- **➕:** markdown to treesitter.lua
- **🐞:** that causes the path of files to extend into the the keymap if too long
- **➕:** NOTE reminder for future Projects section
- **➕:** .gitignore
- **❌:** venv directory from repository
- **➕:** markdown linter and formatter

## v0.4.3a (2025-08-09)

- **🚀:** Lazy update status with periodic background checks

## v0.4.2a (2025-08-08)

- **🚀:** and redesigned dashboard with a new Recent Files section

## v0.4.1a (2025-08-04)

- **♻️:** `require("trouble").setup` to a local variable
- **➕:** linting and formating for various languages
- **♻️:** `require("dracula").setup` to a local variable
- **➕:** status icon for updates to plugins when they populate
- **♻️:** terminal size for more view
- **➕:** colorizer.lua
- **♻️:** `require("lualine").setup` to a local variable
- **➕:** mapping to cycle through windows - CTRL+w
- **❌:** note referencing fixed issue
- **♻️:** `require("nvim-tree").setup` to a local variable
- **➕:** file types to open ALE
- **♻️:** formatting for keymaps
- **♻️:** name of function for clarity
- **♻️:** `require("noice").setup` to a local variable

## v0.4.1a (2025-08-03)

- **➕:** descriptions for keymaps
- **❌:** the pre-buffer setup - `BufReadPre`
- **♻️:** `require("telescope").setup` to a local variable
- **🛠️:** undefined-fields populating by disabling diagnostics
- **♻️:** TroubleToggle to Trouble
- **🛠️:** auto-closing tag when typing ">"
- **♻️:** `require("toggleterm").setup` to a local variable
- **➕:** gitsigns.lua
- **🚀:** all mapping to modern `vim.keymap.set`
- **❌:** comment in alpha.lua

## v0.4.0a (2025-08-02)

- **➕:** comments for cmp.lua dependencies
- **❌:** unnecessary comments
- **❌:** whitspacing
- **🐞:** auto-completion for HTML tags is partically working

## v0.3.0a (2025-08-01)

- **➕:** keymap to open ~/ when attempting to find file in telescope
- **➕:** keymap to open ~/ when attempting to use grep in telescope
- **❌:** unwanted comments
- **➕:** autotag dependency
- **➕:** tree_toggle.lua
- **♻️:** buttons on alpha dashboard to find file and find word
- **➕:** footer and "BUIDL on Avalanche" in ASCII art
- **➕:** Lua, Markdown, and Bash to treesitter.lua

## v0.2.0a (2025-07-25)

- **➕:** todo-comments.lua
- **➕:** LSP configuration setup
- **➕:** alpha configuration with K0D3X ASCII art
- **⚠️:** vim maps
- **❌:** depreciated maps
- **➕:** auto-session
- **➕:** indention icons for clarity
- **➕:** auto-completion setup
- **♻️:** width of sidebar to be wider
- **➕:** icons for open and closed directories
- **➕:** dressing.lua
- **➕:** init.lua to migrate from init.vim
- **🚀:** migration to Lua
- **❌:** init.vim to migrate to init.lua
- **🚀:** mason.lua
- **➕:** dressing.lua

## v0.1.1a (2025-07-24)

- **♻️:** nvim-tree toggle options to its own file
- **➕:** utilities directory
- **🚀:** nvim-tree and the custom toggle options
- **♻️:** leader to CTRL
- **⬆️:** lazy-lock.json - toggleterm
- **❌:** comment that was not needed
- **🚀:** the toggleterm
- **➕:** utility that toggles the terminal
- **♻️:** toggle to utils directory
- **❌:** comments not needed
- **♻️:** width of view for nvim-tree

## v0.1.0a (2025-07-23)

- **➕:** setup and configuration of lazy.nvim
- **➕:** Dracula colorscheme and configured
- **➕:** Lualine and configured
- **➕:** noice.lua and configured
- **➕:** lazy-lock.json
- **➕:** Lazy.lua and configured
- **➕:** LazyGit and configured lazygit.lua

# Glossary

**ADDED** = ➕ **|**
**REMOVED** = ❌ **|**
**FIXED** = 🛠️ **|**
**BUG** = 🐞 **|**
**IMPROVED** = 🚀 **|**
**CHANGED** = ♻️ **|**
**SECURITY** = 🛡️ **|**
**DEPRECIATED** = ⚠️ **|**
**UPDATED** = ⬆️
