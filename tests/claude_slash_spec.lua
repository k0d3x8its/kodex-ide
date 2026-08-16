-- tests/claude_slash_spec.lua
-- Slash-command menu (claude/slash.lua): the "/" picker above the chat bar.
-- Proves: (1) system/init captures slash_commands into state; (2) prefix filter +
-- valid-prefix detection (drives the input-span colour); (3) description resolution
-- from on-disk skill files; (4) the menu float open→move→select→close lifecycle.
-- Run: nvim --headless -u NONE --cmd "set runtimepath+=." -c "luafile tests/claude_slash_spec.lua"

-- Isolate the slash-command disk cache to a temp file BEFORE requiring the module
-- (CACHE_PATH is read at load time) so the fake test list never clobbers the real
-- ~/.local/state cache.
vim.env.KODEX_CLAUDE_SLASH_CACHE = vim.fn.tempname() .. "_slash_cache.json"

local H = dofile("tests/helpers.lua")
H.stub_project_root("/tmp")

-- Subprocess + module stubs (mirror claude_stream_spec.lua).
local captured_stdout_cb = nil
vim.fn.jobstart = function(_, opts)
	captured_stdout_cb = opts.on_stdout
	return 99
end
vim.fn.jobstop = function() end
vim.fn.chansend = function(_, data)
	return #data
end
vim.fn.chanclose = function() end
package.loaded["utils.term_layout"] = { place_vertical = function() end }
package.loaded["utils.claude_diff"] = {
	on_panel_open = function() end,
	on_panel_close = function() end,
	on_diff_open = function() end,
	on_diff_close = function() end,
	watch = function() end,
	poll = function() end,
}
package.loaded["utils.opencode"] = { state = { opencode_active = false }, toggle = function() end }

local claude = require("utils.claude")
claude.setup({ width_pct = 0.40 })
claude.is_available = function()
	return true
end
local slash = require("utils.claude.slash") -- wired by init's slash.wire{}

local function feed(ev)
	captured_stdout_cb(99, { vim.json.encode(ev), "" }, "stdout")
	vim.wait(30)
end

vim.cmd("cd /tmp")
claude.toggle()
vim.wait(30)
claude._send("hello") -- spawns the process, captures on_stdout
vim.wait(30)

-- ── S1: system/init captures slash_commands ──────────────────────────────────
feed({
	type = "system",
	subtype = "init",
	model = "claude-opus-4-8",
	claude_code_version = "2.1.201",
	slash_commands = { "brainstorm", "diagnose", "review", "compact", "changelog" },
})

H.check(
	"S1 slash_commands captured into state",
	type(claude.state.slash_commands) == "table" and #claude.state.slash_commands == 5
)

-- A later empty init must NOT wipe the captured list (fires once per turn).
feed({ type = "system", subtype = "init", model = "claude-opus-4-8", slash_commands = {} })
H.check(
	"S1 later empty init does not clobber the list",
	claude.state.slash_commands ~= nil and #claude.state.slash_commands == 5
)

-- ── S1b: init capture persisted the list to the disk cache; ensure_commands
-- reloads it into a fresh (nil) session so the "/" menu works pre-first-message.
claude.state.slash_commands = nil -- simulate a fresh panel (no init yet)
slash.ensure_commands()
H.check(
	"S1b disk cache reseeds slash_commands before any message",
	claude.state.slash_commands ~= nil and #claude.state.slash_commands == 5
)

-- ── S2: prefix detection (drives input-span colour) ───────────────────────────
H.check("S2 empty query is a valid prefix", slash.has_prefix("") == true)
H.check("S2 'br' matches brainstorm", slash.has_prefix("br") == true)
H.check("S2 'diag' matches diagnose", slash.has_prefix("diag") == true)
H.check("S2 'zzz' matches nothing", slash.has_prefix("zzz") == false)
H.check("S2 'brainx' (past the match) fails", slash.has_prefix("brainx") == false)

-- ── S3: description resolution from on-disk skill files ───────────────────────
-- diagnose + brainstorm are real ~/.claude/skills with description frontmatter.
local d = slash._resolve_desc("diagnose")
H.check("S3 diagnose resolves a non-empty description", type(d) == "string" and #d > 0, tostring(d))
H.check("S3 a bogus command resolves to nil", slash._resolve_desc("definitely-not-a-command-xyz") == nil)

-- ── S4: menu float lifecycle (open → move → select → close) ───────────────────
-- Pin disk discovery to empty so the lifecycle assertions depend only on the known
-- CLI+LOCAL set (real ~/.claude skills would otherwise reorder the sorted menu).
slash._test_disk_names = {}
local ibuf = vim.api.nvim_create_buf(false, true)
H.check("S4 menu starts closed", slash.active() == false)

slash.open(ibuf, "", 3, function() end) -- empty query → all commands, sorted
H.check("S4 menu opens", slash.active() == true)
-- Sorted list includes the LOCAL_COMMANDS (advisor, effort): advisor, brainstorm,
-- changelog, compact, diagnose, effort, review → first is advisor (leading "a").
H.check(
	"S4 first selection is the alphabetical first (advisor)",
	slash.selected() == "advisor",
	tostring(slash.selected())
)

slash.move(1)
H.check("S4 ↓ advances the selection", slash.selected() == "brainstorm", tostring(slash.selected()))
slash.move(-1)
H.check("S4 ↑ returns to the top", slash.selected() == "advisor", tostring(slash.selected()))
slash.move(-1) -- clamp at top
H.check("S4 ↑ clamps at the first row", slash.selected() == "advisor")

-- Re-filter to a prefix: only "c*" commands, selection resets to the top.
slash.open(ibuf, "c", 3, function() end)
H.check("S4 prefix 'c' narrows to changelog/compact", slash.selected() == "changelog", tostring(slash.selected()))

slash.close()
H.check("S4 menu closes", slash.active() == false)

-- Empty-query then a no-match query: menu still opens but has no rows.
slash.open(ibuf, "zzz", 3, function() end)
H.check("S4 no-match query opens an empty menu (no crash)", slash.active() == true and slash.selected() == nil)
slash.close()

-- ── S4c: an ALREADY-OPEN menu with real matches losing them to a no-match query.
-- Distinct from the fresh-open case above (S4's own docs call this "vanish" in
-- the TODO, but the design never auto-closes the menu — Slash.open's re-filter
-- branch just re-renders empty). This exercises that re-filter (`else` branch,
-- slash.lua ~688), not a fresh open.
slash.open(ibuf, "c", 3, function() end) -- real matches (changelog/compact)
H.check("S4c starts open with matches", slash.active() == true and slash.selected() ~= nil)
slash.open(ibuf, "zzz", 3, function() end) -- same ibuf, query now matches nothing
H.check(
	"S4c menu stays OPEN (does not vanish) when an existing filter loses all matches",
	slash.active() == true,
	tostring(slash.active())
)
H.check("S4c selection clears to nil (no stale highlighted row)", slash.selected() == nil, tostring(slash.selected()))
slash.close()

-- ── S4d: Slash.accept() fills the buffer, doesn't submit (Tab-steer bug regression:
-- init.lua's Tab handler used to feed <CR> via nvim_feedkeys in noremap mode, which
-- bypasses the menu's buffer-local <CR> map and hit the prompt buffer's raw <CR>
-- instead — submitting the half-typed command as a message. Slash.accept() is now
-- called directly, no feedkeys involved).
slash.open(ibuf, "c", 3, function() end) -- real matches (changelog/compact)
H.check("S4d starts open on a real prefix", slash.active() == true and slash.selected() ~= nil)
local accepted_name = slash.selected()
-- ibuf here is a plain scratch buffer (not buftype=prompt, see line 103), so
-- prompt_getprompt returns "" and accept() writes "/name " with no arrow prefix —
-- matches accept_selected's own `prompt .. text` composition for that case.
vim.api.nvim_buf_set_lines(ibuf, -2, -1, false, { "/" .. accepted_name:sub(1, 1) })
slash.accept()
H.check("S4d accept() closes the menu", slash.active() == false)
H.check(
	"S4d accept() fills the full command name into the buffer",
	vim.api.nvim_buf_get_lines(ibuf, -2, -1, false)[1] == "/" .. accepted_name .. " ",
	vim.inspect(vim.api.nvim_buf_get_lines(ibuf, -2, -1, false))
)

-- accept() is a no-op when the menu isn't open (nothing to fill, nothing to close).
slash.close()
H.check("S4d accept() no-ops when menu is closed", slash.accept() == nil and slash.active() == false)

-- ── S4b: disk-discovered skills populate the menu (new-skill auto-population) ───
-- The reported bug: skills created AFTER the CLI advertised its slash_commands[]
-- snapshot never showed. Fix: the menu also sources names from the on-disk skill/
-- command files, merged + deduped in all_commands(). Proven three ways.

-- (a) Real disk scan finds real skills (un-namespaced basenames).
local disk = slash._disk_command_names()
local function has(list, name)
	for _, n in ipairs(list) do
		if n == name then
			return true
		end
	end
	return false
end
H.check(
	"S4b disk scan returns a non-empty name list",
	type(disk) == "table" and #disk > 0,
	"n=" .. tostring(disk and #disk)
)
H.check("S4b disk scan finds a real skill dir (diagnose)", has(disk, "diagnose"), table.concat(disk or {}, ","))

-- (b) A disk-only skill NOT in the CLI-advertised list still becomes a known command.
claude.state.slash_commands = { "review", "compact" } -- CLI list WITHOUT the skill
slash._test_disk_names = { "my-brand-new-skill", "diagnose" }
slash._refresh_disk_names()
H.check(
	"S4b disk-only skill is a known command (was absent from slash_commands)",
	slash.is_command("my-brand-new-skill") == true
)
H.check(
	"S4b disk-only skill appears in the merged command universe",
	has(slash._all_commands(), "my-brand-new-skill"),
	table.concat(slash._all_commands(), ",")
)

-- (c) A disk name that shares a display SUFFIX with a namespaced advertised command
-- is a distinct command, not a duplicate — batch-5 /code-crit (adversarial): the old
-- suppress-on-suffix-collision behaviour let an advertised "evil:tdd" hide a real
-- local "tdd" the user could otherwise have run, with no way to tell one had vanished.
-- Both must now survive in the universe (exact full-name identity is the only thing
-- push() dedupes), and render_menu falls back to showing the FULL name for either row
-- once their display labels collide (see label_counts in render_menu).
claude.state.slash_commands = { "caveman:caveman", "review" }
slash._test_disk_names = { "caveman", "my-brand-new-skill" }
slash._refresh_disk_names()
local all = slash._all_commands()
local caveman_count = 0
for _, n in ipairs(all) do
	if n == "caveman" then
		caveman_count = caveman_count + 1
	end
end
H.check(
	"S4b disk 'caveman' survives alongside the namespaced 'caveman:caveman' (not suppressed)",
	caveman_count == 1,
	"count=" .. caveman_count .. " all=" .. table.concat(all, ",")
)
H.check("S4b the namespaced original is still present", has(all, "caveman:caveman"))

-- Restore neutralised disk discovery for the remaining specs.
slash._test_disk_names = {}
claude.state.slash_commands = { "brainstorm", "diagnose", "review", "compact", "changelog" }

-- ── S5: prompt-prefixed integration (the real chat-bar path) ──────────────────
-- REGRESSION: a prompt buffer keeps the "❯ " prompt AS part of the buffer line, so
-- the real typed line is "❯ /cmd", not "/cmd". update_slash_menu must strip the
-- prompt before matching, else the menu never opens live (the shipped-then-fixed
-- bug). Drive the REAL chat float: set a prompt-prefixed line + fire TextChangedI.
claude._open_chat_float("Reply to Claude", function() end)
vim.wait(30)
local cbuf = claude.state.chat_buf
local prompt = vim.fn.prompt_getprompt(cbuf)
local islash_ns = vim.api.nvim_get_namespaces()["claude_slash_input"]
local function type_prompt_line(s)
	vim.api.nvim_buf_set_lines(cbuf, -2, -1, false, { prompt .. s })
	vim.api.nvim_exec_autocmds("TextChangedI", { buffer = cbuf })
	vim.wait(30)
end
local function span_hl()
	local m = vim.api.nvim_buf_get_extmarks(cbuf, islash_ns, 0, -1, { details = true })
	return m[1] and m[1][3], m[1] and m[1][4].hl_group -- start col, hl
end

type_prompt_line("/br")
H.check(
	"S5 menu opens on a prompt-prefixed '/br' (prompt stripped)",
	slash.active() == true,
	tostring(slash.selected())
)
local col, hl = span_hl()
H.check("S5 colour span starts after the prompt (col == prompt bytelen)", col == #prompt, tostring(col))
H.check("S5 valid prefix colours ClaudeSlashMatch", hl == "ClaudeSlashMatch", tostring(hl))

type_prompt_line("/zzznope")
local _, hl2 = span_hl()
H.check("S5 no-match leaves the span PLAIN (no highlight, not red)", hl2 == nil, tostring(hl2))

type_prompt_line("/brainstorm ") -- trailing space => command chosen, menu closes
H.check("S5 a space after the command closes the menu", slash.active() == false)

-- ── S6: is_command exact match (full name + post-":" suffix) ───────────────────
claude.state.slash_commands = { "brainstorm", "compound-engineering:ce-code-review" }
H.check("S6 exact full name is a command", slash.is_command("brainstorm") == true)
H.check("S6 namespaced suffix is a command", slash.is_command("ce-code-review") == true)
H.check("S6 full namespaced name is a command", slash.is_command("compound-engineering:ce-code-review") == true)
H.check("S6 a partial prefix is NOT an exact command", slash.is_command("brain") == false)
H.check("S6 an unknown token is not a command", slash.is_command("nope-xyz") == false)

-- ── S7: highlight a valid "/command" ANYWHERE in the line (not just col 0) ─────
-- A command mid-sentence (after other text) must colour ClaudeSlashMatch over the
-- "/token" span; the picker menu stays closed (it's not a bare leading "/query").
type_prompt_line("please run /brainstorm now")
H.check("S7 mid-line command leaves the picker closed", slash.active() == false)
do
	local marks = vim.api.nvim_buf_get_extmarks(cbuf, islash_ns, 0, -1, { details = true })
	local found = false
	local line = vim.api.nvim_buf_get_lines(cbuf, -2, -1, false)[1]
	local at = line:find("/brainstorm", 1, true) - 1 -- 0-based byte col of "/"
	for _, m in ipairs(marks) do
		if m[3] == at and m[4].hl_group == "ClaudeSlashMatch" then
			found = true
		end
	end
	H.check("S7 the mid-line '/brainstorm' span is highlighted", found, tostring(#marks))
end

-- A mid-line "/notacommand" must NOT be highlighted.
type_prompt_line("run /notacommand now")
do
	local marks = vim.api.nvim_buf_get_extmarks(cbuf, islash_ns, 0, -1, { details = true })
	H.check("S7 a bogus mid-line command is not highlighted", #marks == 0, tostring(#marks))
end

-- Mid-line highlight tracks a live PREFIX: a half-typed "/brai" stays lit (prefix
-- of brainstorm); one more wrong letter "/braix" drops back to plain.
local function has_midline_mark()
	return #vim.api.nvim_buf_get_extmarks(cbuf, islash_ns, 0, -1, {}) > 0
end
type_prompt_line("go /brai")
H.check("S7b a valid mid-line prefix stays highlighted", has_midline_mark() == true)
type_prompt_line("go /braix")
H.check("S7b an invalid mid-line prefix turns plain", has_midline_mark() == false)

-- ── S6c: is_command's unambiguous-suffix gate (batch-5 adversarial finding
-- slash.lua:469) — a forgeable trust signal was fixed by requiring the suffix be
-- unique before granting the "known command" highlight. The gate only changes the
-- outcome when NO bare entry named `name` exists anywhere (see is_command's own
-- doc) — this is the one reachable case: two different namespaced names sharing a
-- suffix with no bare command of that name.
slash._test_disk_names = {}
claude.state.slash_commands = { "pluginA:shared", "pluginB:shared" }
slash._refresh_disk_names()
H.check(
	"S6c ambiguous suffix (two namespaced names, no bare entry) is NOT a known command",
	slash.is_command("shared") == false
)
-- A single namespaced name's suffix is still trusted (the unambiguous case).
claude.state.slash_commands = { "pluginA:onlyone" }
slash._refresh_disk_names()
H.check("S6c unambiguous suffix is still a known command", slash.is_command("onlyone") == true)
-- A real bare entry is trusted regardless of an unrelated namespaced collision.
claude.state.slash_commands = { "pluginA:tdd", "pluginB:tdd" }
slash._test_disk_names = { "tdd" }
slash._refresh_disk_names()
H.check(
	"S6c a genuine bare entry is trusted even when its suffix is separately ambiguous",
	slash.is_command("tdd") == true
)
slash._test_disk_names = {}

-- ── S8: is_valid_name (batch-5 security/adversarial: reject a hostile basename
-- before it reaches the menu buffer or an outgoing prompt insertion) ────────────
H.check("S8 a normal skill name is valid", slash._is_valid_name("code-review") == true)
H.check("S8 a namespaced name is valid", slash._is_valid_name("plugin:skill") == true)
H.check("S8 an embedded newline is rejected", slash._is_valid_name("foo\nbar") == false)
H.check("S8 an empty string is rejected", slash._is_valid_name("") == false)
H.check("S8 a non-string is rejected", slash._is_valid_name(42) == false)
H.check("S8 a name over the length cap is rejected", slash._is_valid_name(string.rep("a", 81)) == false)

H.summary("claude_slash")
