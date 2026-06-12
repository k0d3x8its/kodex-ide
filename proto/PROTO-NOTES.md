# Goal 3 diff-workflow prototype — ANSWERED 2026-06-11

**Question:** Does checktime → FileChangedShell → queued vimdiff work for edits made
by a child process inside `:terminal`, and does reject-all write-back avoid an
infinite re-queue loop?

**Answer: YES — mechanism validated end-to-end (9 hard cases, `bash proto/run_proto.sh`,
ALL PASS), but only with four corrections to the planned design (findings.md Q6).**

## Corrections the real implementation MUST carry

1. **`'autoread'` must be OFF while `opencode_active`** (restore on panel close).
   With autoread set (Neovim default ON) and an unmodified buffer, FileChangedShell
   is *not triggered at all* — Neovim silently reloads. The interceptor never runs.

2. **`v:fcs_choice = "ignore"` is not a valid value** — docs: invalid values silently
   behave like `""` (empty = autocmd handles everything). Plan worked by accident.
   Use `vim.v.fcs_choice = ""` explicitly. Still must be set synchronously in the callback.

3. **Per-buffer checktime loop, not bare `:checktime`.** Bare checktime fires
   FileChangedShell only for the CURRENT buffer; hidden buffers never fire and repeat
   passes don't recover the event. Loop `:checktime {bufnr}` over loaded `buftype==""`
   buffers (`checktime_all()` in diff_proto.lua). Without this, multi-file opencode
   edits are silently lost for any buffer not in a window.

4. **`nested = true` on the TermLeave/WinEnter/CursorHold trigger autocmd.**
   Autocmds don't nest by default: checktime running inside the trigger autocmd
   suppresses the FileChangedShell it causes → default W11 warning path, interceptor
   bypassed. (Headless tests calling checktime directly never catch this — only the
   real autocmd path does.)

5. **`:write!` (bang) in BOTH accept-all and reject-all.** Disk changed since last
   *read* and the FCS event doesn't sync the read-timestamp the overwrite check uses.
   Plain `:w` prompts "WARNING: The file has been changed since reading it!!!" and
   blocks. Verified: after reject's `write!`, two further checktime passes fire
   nothing — re-queue loop is dead.

## Validated as planned (no change)

- Queue + dedup (against current diff and queued entries) works; one diff at a time,
  auto-advance on resolve.
- Scratch `[OpenCode proposed]` buffer + `diffthis` pair; buffer-local accept/reject
  keymaps on scratch only.
- `vim.schedule(process_next)` out of the FCS callback (window ops forbidden inside).
- Local-unsaved-edits case detectable via `vim.bo[buf].modified` in the callback (warn).
- Full fidelity confirmed: child process inside real `:terminal` + WinEnter-driven
  checktime catches the edit (T8).

## Files

- `diff_proto.lua` — validated mechanism; basis of real `lua/utils/opencode_diff.lua`
  (rename, wire `state.active` → `opencode.state.opencode_active`, real `<leader>oa/ox`,
  add autoread save/restore on panel open/close).
- `diff_proto_test.lua` + `run_proto.sh` — hard-case suite; treat as the implementation spec.
- `diff_proto_interactive.lua` (`run_proto.sh -i`) — manual feel-check.
- iso*.lua isolation scripts deleted — findings absorbed above.
