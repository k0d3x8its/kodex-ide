# kodex-ide Knowledge

> Empirical facts about this codebase and its runtime behavior.
> Promoted via /remember or /checkpoint. Committed with the repo.

---

- `toggleterm` Terminal:shutdown() may not fire on_close — call cleanup hooks explicitly in any reset/destroy path that calls shutdown() directly.
- Neovim Lua headless tests can stub plugins via `package.loaded['plugin.module'] = { ... }` before requiring the real module — lets the suite exercise real autocmd behavior without the full lazy.nvim stack.
- `auto-session` `get_latest_session(dir)` returns highest-mtime session in dir regardless of path — can return parent dirs (e.g. `~/dev`); filter against known project list before using.
- auto-session percent-encodes session filenames: `/home/k0d3x/dev/proj` → `%2Fhome%2Fk0d3x%2Fdev%2Fproj.vim`; use `Lib.escape_session_name(path) .. ".vim"` to locate a session file by project path.
