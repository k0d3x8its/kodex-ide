# Changelog

## [Unreleased]

### 2026-06-13
#### Added
- ➕ Dock-launch project pick now prompts "Restore session" vs "New session" when the chosen project already has a saved session, instead of silently auto-restoring [\[00b8c25\]](https://github.com/k0d3x8its/kodex-ide/commit/00b8c25f28b78d9e83903803509c66be447e4be5)
- ➕ Headless test harness — `make test` runs each `tests/*_spec.lua` in its own `nvim --headless -u NONE`, covering the diff-queue mechanism (9 hard cases) plus regressions for every v1.1.0 review fix [\[c334e18\]](https://github.com/k0d3x8its/kodex-ide/commit/c334e18d7e15ee311a881b0231f86e49f62362a2) [\[ce2fff9\]](https://github.com/k0d3x8its/kodex-ide/commit/ce2fff9ed9ada98f1004913a06830604fe530bda) [\[abfcfbf\]](https://github.com/k0d3x8its/kodex-ide/commit/abfcfbf048616578090ce6f7d22c1424616839d6) [\[a9c6dab\]](https://github.com/k0d3x8its/kodex-ide/commit/a9c6dabcefb9267d9f06fe7c9dfaea705e251029) [\[4df5d31\]](https://github.com/k0d3x8its/kodex-ide/commit/4df5d31f5b83227d3d0331df96b5f384f9ed985a)

#### Fixed
- 🛠️ Hardened the OpenCode diff workflow — drains the queue when a queued file has no open buffer, survives an opencode-deleted file, guards an invalidated original buffer, and on a failed accept/reject write now notifies and keeps the diff open rather than silently advancing as if the revert succeeded (prevented a data-loss case where changes stayed on disk) [\[49e5f7e\]](https://github.com/k0d3x8its/kodex-ide/commit/49e5f7e45775957f8d69de668405ad8c07b5e3df)

#### Changed
- ♻️ Hardened OpenCode panel internals — shared availability guard, warm-job send delay (50 ms vs 500 ms cold boot), and a `selection=exclusive`-aware visual-selection trim [\[002a537\]](https://github.com/k0d3x8its/kodex-ide/commit/002a537163fd658b8376607d85ec18399bb7a4ae)
- ♻️ Migrated the deprecated `vim.loop` to `vim.uv` across the init bootstrap, keymaps, and PlatformIO status [\[1f2a11d\]](https://github.com/k0d3x8its/kodex-ide/commit/1f2a11d8535ed3cf0a34cd8e2e2c9811fb5ed575) [\[a92f996\]](https://github.com/k0d3x8its/kodex-ide/commit/a92f99661d94f054a509c3433bb06fe02436aa47) [\[b4cd97f\]](https://github.com/k0d3x8its/kodex-ide/commit/b4cd97f36ece96c075a84108a6b04e23c5e90f20)
- ♻️ Recorded `make test` as the repo's verify command in KNOWLEDGE.md [\[658867f\]](https://github.com/k0d3x8its/kodex-ide/commit/658867f7fc43f9cbb6ee8f342902d44359c48f56)

#### Removed
- ❌ Deleted the dead `lua/core/lazy.lua` bootstrap duplicate — `init.lua` already bootstraps lazy.nvim inline [\[bd69cdc\]](https://github.com/k0d3x8its/kodex-ide/commit/bd69cdc8e1fe853db7ff0845fa0e6b2437bad0c9)

## v1.1.0 (2026-06-13)
#### Added
- ➕ Project picker on launch — `KODEX_IDE=1` triggers a project chooser at `VimEnter` so the IDE opens straight into a chosen project [\[c5e813f\]](https://github.com/k0d3x8its/kodex-ide/commit/c5e813f7795ab7aa57ca0380ef04b6ea9f8ab516)
- ➕ Project picker utility backing the launch chooser [\[6f942a5\]](https://github.com/k0d3x8its/kodex-ide/commit/6f942a5f12e0dbd91170c1dffd62225bc0156b21)
- ➕ File tree now roots at the selected project's cwd instead of a fixed `~/dev`, with `<C-s>` bound to toggle the tree rooted at project cwd [\[6f86630\]](https://github.com/k0d3x8its/kodex-ide/commit/6f8663054ad9be8c7535b2d1159a7d29cb892e80)
- ➕ nvim-tree toggle rooted at project cwd rather than the hard-coded `~/dev` path [\[2649f39\]](https://github.com/k0d3x8its/kodex-ide/commit/2649f397e31886da6565795df9a20479db5d37c1)
- ➕ Fresh project pick opens the sidebar immediately and defers the OpenCode panel until the first file is chosen [\[5d00972\]](https://github.com/k0d3x8its/kodex-ide/commit/5d00972d8ddf34db609a9158f196121b65ea6f1e)
- ➕ Bufferline tab stays labelled by the active file even when the OpenCode panel holds focus [\[5c89c9f\]](https://github.com/k0d3x8its/kodex-ide/commit/5c89c9f72a3038ae9e0489d411f55b6953e13838)
- ➕ OpenCode terminal buffer renamed to `opencode` for a clean statusline label [\[e2f09f8\]](https://github.com/k0d3x8its/kodex-ide/commit/e2f09f8e9874de411735cb471d5c164a69bead24)
- ➕ `ask_selection()` sends the current visual selection plus a question to OpenCode [\[124273f\]](https://github.com/k0d3x8its/kodex-ide/commit/124273f8f71f1b2a3f75e5bb6f1b4a03b10616f0)
- ➕ `<leader>oq` visual-mode keymap wired to the OpenCode ask-selection flow [\[5d9ff3c\]](https://github.com/k0d3x8its/kodex-ide/commit/5d9ff3c8f8342a6cbc926a32105c2b5e48fc5f3d)

#### Fixed
- 🛠️ OpenCode ask now flushes visual marks before reading the selection, so the correct range is sent [\[6dbb600\]](https://github.com/k0d3x8its/kodex-ide/commit/6dbb60004f8c8947a8207ba6b5059e4076938427)
- 🛠️ Auto-session restore purges terminal buffers in `pre_save_cmds`, preventing the "Invalid terminal direction" error on reload [\[774fb2b\]](https://github.com/k0d3x8its/kodex-ide/commit/774fb2bed109bda2dd4c9be9d87948d8aa73a53a)
- 🛠️ Resume-last-session scoped to `~/dev/*` projects only, so it no longer fires in unrelated directories [\[81d9feb\]](https://github.com/k0d3x8its/kodex-ide/commit/81d9feb920248fe90221a1d9de38901d9e2ea247)
- 🛠️ Dashboard Recent Files auto-widths so `SPC N` labels no longer overlap file paths [\[982ea4a\]](https://github.com/k0d3x8its/kodex-ide/commit/982ea4a7eb68f23e432ac5875d35ccd6432b5e17)
- 🛠️ nvim-notify `background_colour` set to silence the `NotifyBackground` warning [\[e0ff97e\]](https://github.com/k0d3x8its/kodex-ide/commit/e0ff97e3703b6f2605af9bf7ceef3261a593ce48)
- 🛠️ `<Esc>` now passes through to the OpenCode TUI in terminal mode [\[1548630\]](https://github.com/k0d3x8its/kodex-ide/commit/1548630393fa23c4cc0249cd43339683bb3f5948)

#### Changed
- ❌ Removed throwaway `proto/` scaffolding after the diff workflow was verified [\[3c2d1bc\]](https://github.com/k0d3x8its/kodex-ide/commit/3c2d1bc3ff0d26a22dc0fd1c029df745e4b55777)
- ♻️ Fixed string-concat indentation in `opencode_diff` [\[c308ca1\]](https://github.com/k0d3x8its/kodex-ide/commit/c308ca1e5642c6179ce929222aebf4942f2d70a7)
- ⬆️ Refreshed the plugin lockfile [\[199b8df\]](https://github.com/k0d3x8its/kodex-ide/commit/199b8df3ac572b9a0a004fb5078b79d7230e994a)

## v1.0.1b (2026-05-24)

- **♻️:** update install instructions for the `kodex-ide` repo
- **🛠️:** use a config-local Python host path instead of a hard-coded user path
- **➕:** expose the Alpha dashboard command for lazy loading
- **🛠️:** pin `nvim-treesitter` to the compatible `master` branch
- **⬆️:** refresh the plugin lockfile for the latest dependency pins

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
