-- tests/claude_search_rate_limit_spec.lua
-- Regression coverage for two Goal 12 Batch 2 fixes that had zero prior
-- coverage: widgets.search_descriptor's compound-command gate (a chained Bash
-- command must fall back to the generic render, but a quoted-pipe regex
-- alternation like `rg "foo|bar"` must NOT be misclassified as chained) and
-- render.lua's is_rate_limit_blocking status classifier (the "allow" substring
-- match used to treat "not_allowed"/"disallowed" as safe).
-- Run: nvim --headless -u NONE --cmd "set runtimepath+=." -c "luafile tests/claude_search_rate_limit_spec.lua"

local H = dofile("tests/helpers.lua")
local widgets = require("utils.claude.widgets")
local render = require("utils.claude.render")

-- ── search_descriptor: compound-command gate ──────────────────────────────────
H.check(
	"search_descriptor: plain rg command classified as search",
	widgets.search_descriptor("Bash", { command = "rg foo lua/" }) ~= nil
)

H.check(
	"search_descriptor: quoted pipe (regex alternation) still classified as search",
	(function()
		local sd = widgets.search_descriptor("Bash", { command = [[rg "foo|bar" lua/]] })
		return sd ~= nil and sd.pattern == "foo|bar"
	end)()
)

H.check(
	"search_descriptor: semicolon-chained command falls back (nil)",
	widgets.search_descriptor("Bash", { command = "grep foo; rm -rf ~" }) == nil
)

H.check(
	"search_descriptor: &&-chained command falls back (nil)",
	widgets.search_descriptor("Bash", { command = "cd /x && grep foo && rm -rf ~" }) == nil
)

H.check(
	"search_descriptor: backtick command substitution falls back (nil)",
	widgets.search_descriptor("Bash", { command = "grep `whoami`" }) == nil
)

-- ── search_descriptor: files_mode trailing-flag frontier fix ─────────────────
H.check(
	"search_descriptor: trailing -l flag classified as files mode",
	(function()
		local sd = widgets.search_descriptor("Bash", { command = "rg foo -l" })
		return sd ~= nil and sd.files == true
	end)()
)

-- ── is_rate_limit_blocking: exact/prefix anchoring ────────────────────────────
H.check("rate_limit: 'allowed' is not blocking", render._is_rate_limit_blocking("allowed") == false)
H.check("rate_limit: 'ok' is not blocking", render._is_rate_limit_blocking("ok") == false)
H.check(
	"rate_limit: 'warning_approaching' is not blocking",
	render._is_rate_limit_blocking("warning_approaching") == false
)
H.check("rate_limit: 'not_allowed' IS blocking", render._is_rate_limit_blocking("not_allowed") == true)
H.check("rate_limit: 'disallowed' IS blocking", render._is_rate_limit_blocking("disallowed") == true)
H.check("rate_limit: 'allowance_exceeded' IS blocking", render._is_rate_limit_blocking("allowance_exceeded") == true)
H.check("rate_limit: non-string status is not blocking", render._is_rate_limit_blocking(nil) == false)

H.summary("claude_search_rate_limit")
