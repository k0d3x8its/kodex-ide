# Mutation Testing Protocol — Claude Code Panel

Manual mutation protocol for `lua/utils/claude_diff.lua` and `lua/utils/claude.lua`.
Run `make test` baseline first (all pass). Apply each mutation, re-run `make test`,
confirm the listed test **FAILS**. Revert mutation before moving to next.

---

## Baseline

```bash
make test
# Expected: ALL PASS
```

Baseline must be green before starting. A red baseline makes mutation results ambiguous.

---

## Mutations

### M1 — Remove autoread=false (CORRECTION #1)

**File:** `lua/utils/claude_diff.lua`  
**Change:** In `on_panel_open()`, delete the line `vim.o.autoread = false`  
**Expected failure:** `T15 CORRECTION #1 — on_panel_open sets autoread=false`  
**Why this matters:** Without disabling autoread, Neovim silently reloads files that
change on disk, consuming the `FileChangedShell` event before our interceptor fires.
The entire diff-review workflow silently breaks.

```diff
-  vim.o.autoread = false
```

---

### M2 — Wrong fcs_choice value (CORRECTION #2)

**File:** `lua/utils/claude_diff.lua`  
**Change:** In the `FileChangedShell` callback, change `vim.v.fcs_choice = ""`
to `vim.v.fcs_choice = "ignore"`  
**Expected failure:** `T16 CORRECTION #2 — diff opens (implies fcs_choice was '' not 'ignore')`  
**Why this matters:** `"ignore"` is not a valid `fcs_choice` in modern Nvim and its
behaviour is version-dependent. `""` (empty string) is the canonical "let the event
proceed" value. Wrong value → diff never opens.

```diff
-  vim.v.fcs_choice = ""
+  vim.v.fcs_choice = "ignore"
```

---

### M3 — Bare checktime instead of per-buffer (CORRECTION #3)

**File:** `lua/utils/claude_diff.lua`  
**Change:** In `checktime_all()`, replace `vim.cmd("checktime " .. bufnr)` with
`vim.cmd("checktime")`  
**Expected failure:** `T7 both fired` or `T7 second diff auto-opens after first resolved`  
**Why this matters:** Bare `checktime` (no arg) checks ALL loaded buffers atomically.
This prevents the dedup logic from running between files — both FCS events fire in
the same synchronous pass, the second one is dropped, and the multi-file queue never
drains correctly.

```diff
-  vim.cmd("checktime " .. bufnr)
+  vim.cmd("checktime")
```

---

### M4 — Remove nested=true from WinEnter autocmd (CORRECTION #4)

**File:** `lua/utils/claude_diff.lua`  
**Change:** In `ensure_autocmds()`, remove `nested = true` from the `WinEnter`
autocmd that calls `checktime_all()`  
**Expected failure:** `T8 WinEnter autocmd caught terminal-child edit`  
**Why this matters:** `checktime` itself fires `FileChangedShell`, which is a Neovim
event. Without `nested = true`, autocmds triggered inside the `WinEnter` callback
(including `FileChangedShell`) are suppressed. The terminal-child edit path goes
silently silent.

```diff
-    nested = true,
```

---

### M5 — Remove write-bang in accept_all (CORRECTION #5)

**File:** `lua/utils/claude_diff.lua`  
**Change:** In `accept_all()`, change `vim.cmd("write!")` to `vim.cmd("write")`  
**Expected failure:** `T6 buffer written, not modified` (on a file where the buffer
has unsaved local edits — write without `!` refuses to overwrite)  
**Setup:** Before running the test, make the target file read-only or add local edits:
```bash
chmod 444 /tmp/kodex_claude_diff_ws/alpha.txt
```
**Why this matters:** If a buffer has local unsaved edits when accept is called,
bare `write` refuses and the accept silently fails, leaving the file on disk in the
pre-accept state. The user thinks they accepted but the old content stays.

```diff
-  vim.cmd("write!")
+  vim.cmd("write")
```

---

### M6 — Remove write-bang in reject_all (CORRECTION #5, second site)

**File:** `lua/utils/claude_diff.lua`  
**Change:** In `reject_all()`, change `vim.cmd("write!")` to `vim.cmd("write")`  
**Expected failure:** `T13 failed reject keeps diff open (no silent advance)` — BUT
the failure mode changes: a previously clean file now silently fails the write and
incorrectly advances the queue (the "no silent advance" guarantee breaks)  
**Why this matters:** Same as M5 but on the restore path. CORRECTION #5 must be
applied to BOTH accept_all and reject_all.

```diff
-  vim.cmd("write!")
+  vim.cmd("write")
```

---

### M7 — Break stdout chunk accumulation

**File:** `lua/utils/claude.lua`  
**Change:** In `on_stdout()`, after the `vim.split(stdout_buf, "\n", ...)` call,
replace the tail-preservation line with a discard:

```diff
-  stdout_buf = table.remove(lines)  -- keep tail for next call
+  stdout_buf = ""                   -- MUTATION: discard tail
```

**Expected failure:** `T13 split-chunk event reassembled + rendered`  
**Why this matters:** The libuv layer delivers stdout in arbitrary chunks. A JSON
event can arrive split across two calls (e.g., chunk 1 = first 20 bytes, chunk 2 =
rest + newline). Discarding the tail means the second chunk alone is not valid JSON
and is silently dropped — the entire event is lost, nothing renders.

---

### M8 — Wrong augroup name (A4 regression)

**File:** `lua/utils/claude_diff.lua`  
**Change:** In `ensure_autocmds()`, change the augroup name from `"ClaudeDiff"` to
`"OpencodeDiff"`:

```diff
-  vim.api.nvim_create_augroup("ClaudeDiff",   { clear = true })
+  vim.api.nvim_create_augroup("OpencodeDiff", { clear = true })
```

**Expected failure:** `T14 OpencodeDiff augroup has autocmds` → fails (it was just
cleared by the ClaudeDiff registration)  
**Why this matters:** Both diff modules use `augroup ... { clear = true }`. If they
share a name, the second registration wipes the first's autocmds. The opencode diff
interceptor goes silent the moment the Claude panel opens.

---

## Cheat Sheet

| Mutation | File | Symbol | Expected failing test |
|----------|------|--------|----------------------|
| M1 | claude_diff.lua | `on_panel_open` | T15 |
| M2 | claude_diff.lua | FCS callback | T16 |
| M3 | claude_diff.lua | `checktime_all` | T7 |
| M4 | claude_diff.lua | WinEnter autocmd | T8 |
| M5 | claude_diff.lua | `accept_all` | T6 |
| M6 | claude_diff.lua | `reject_all` | T13 |
| M7 | claude.lua | `on_stdout` | T13 (claude_spec) |
| M8 | claude_diff.lua | augroup name | T14 |
