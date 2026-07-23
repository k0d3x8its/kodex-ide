# Prototype answer — Claude panel Artifacts bar

**Question:** what should the session-persistent Artifacts bar look like, and
which click/keyboard affordances feel right?

**Answer (locked 2026-07-06):**

- **Bar look:** numbered, keyboard-first — `[1] name  [2] name …` in a rounded
  bordered card titled ` ◈ Artifacts (1-9 to open) `, bottom-pinned SW, zindex 30.
  (Variant 3 of the proto. Rejected: bordered `◈ name · name`, flush borderless strip.)
- **Open affordance:** press `1`–`9` to open the Nth artifact URL in the browser
  (`vim.ui.open`). **No mouse click on the bar** — non-focusable float made
  `getmousepos().winid` unreliable, and screen-cell resolution wasn't worth it.
- **Inline transcript link:** the `└ published · <name>` line under each
  `● Artifact` header IS mouse-clickable (panel is a normal focusable window, so
  `getmousepos()` resolves it). This covers "open from where I'm reading."
- **`published` line:** nested under the `● Artifact` header with a `└` corner
  (matches `render_tool_result`), name is the clickable span.
- **Lifetime:** bar persists the whole session; cleared (hidden) on `<leader>cr`.

## Fold into real code
- `render.lua` tool_use branch (~1391): `name == "Artifact"` → append
  `{id, name, favicon, url=nil}` to `state.artifacts`; fill `url` at the correlated
  `tool_result` (via `state.tool_meta[id]`). Render the `└ published` corner inline.
- `widgets.lua`: `update_artifact_bar()` (variant-3 render) + register in
  `reflow_bottom_floats()`; `1-9` open maps; teardown on session clear.
- Inline link: reuse the panel's existing click handling; store link extents per
  artifact for resolution.

Delete `proto/artifacts_bar.lua` + this file once absorbed.
