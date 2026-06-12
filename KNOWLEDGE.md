# kodex-ide Knowledge

> Empirical facts about this codebase and its runtime behavior.
> Promoted via /remember or /checkpoint. Committed with the repo.

---

- `toggleterm` Terminal:shutdown() may not fire on_close — call cleanup hooks explicitly in any reset/destroy path that calls shutdown() directly.
- Neovim Lua headless tests can stub plugins via `package.loaded['plugin.module'] = { ... }` before requiring the real module — lets the suite exercise real autocmd behavior without the full lazy.nvim stack.
