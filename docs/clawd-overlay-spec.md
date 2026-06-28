# Clawd Overlay Spec for Kodex IDE

## Purpose

Add a Clawd-style animated pet overlay to the existing Claude Code integration in Kodex IDE.

The overlay should render the original animation assets from the Clawd repo rather than an ASCII approximation.
The goal is to make the pet feel like a first-class companion to the Claude panel:

- sleep when Claude is inactive
- wake when the Claude chat bar appears
- reflect Claude's real work states while Claude is processing
- show a progressive idle loop when Claude is done and nobody interacts

This document is intentionally implementation-oriented so another LLM can review it and then turn it into code.

## Non-Goals

- Do not replace the existing Claude panel or chat bar.
- Do not redraw the pet as ASCII art.
- Do not couple the pet to arbitrary editor activity outside the Claude workflow unless explicitly noted.
- Do not change the current Claude state machine unless the pet integration requires a narrow hook.
- Do not assume SVG is the primary runtime animation format.

## Current Repository Context

The existing Claude integration already has enough state to drive the pet:

- [`lua/utils/claude.lua`](/home/k0d3x/dev/kodex-ide/lua/utils/claude.lua)
- [`lua/plugins/claude.lua`](/home/k0d3x/dev/kodex-ide/lua/plugins/claude.lua)
- [`lua/plugins/ui.lua`](/home/k0d3x/dev/kodex-ide/lua/plugins/ui.lua)

The current Claude implementation already exposes:

- `state.claude_active`
- `state.panel_win`
- `state.job_id`
- `state.working`
- `state.diff_pending`
- `state.system_ready`
- `state.session_cost`
- `state.model_display`
- `dispatch(event)`
- `open_chat_float(...)`
- `prompt_input()`
- `toggle()`
- `open_panel_window(buf)`
- `on_diff_open()`
- `on_diff_close()`
- `interrupt()`

That means the pet can be driven from existing Claude lifecycle events rather than from global editor state.

## Assets

The Clawd repo uses SVGs and GIFs.

For this integration:

- use GIFs as the runtime animation source
- treat SVGs as source art or static fallback assets
- do not design the implementation around SVG playback unless a renderer-specific proof succeeds

Reasoning:

- GIFs are the most direct fit for animated runtime behavior.
- SVG is better suited to source art, static art, or conversion pipelines.
- The user explicitly wants the original look preserved, and GIFs are the closest match to that requirement in a terminal image overlay.

## Rendering Assumption

Use a terminal image rendering bridge inside Neovim.

The working assumption is:

- Ghostty terminal
- Neovim image overlay support via a renderer such as `image.nvim`
- floating window placement for the pet

The renderer must support:

- floating windows
- animated image display or frame swapping
- repositioning on resize
- clean teardown without leaving artifacts

If a renderer cannot animate GIFs directly, the fallback is to advance frames manually from the GIF source or pre-extract frames into image assets. The implementation should not degrade to ASCII unless there is no viable image path.

## Core Behavior

The pet is a state-driven overlay, not a decorative widget.

It should represent:

- Claude being inactive
- Claude waking up
- Claude typing
- Claude reading files
- Claude debugging
- Claude cleaning files or directories
- Claude handling errors
- Claude waiting on diff approval
- Claude being approved
- Claude being rejected
- Claude subagent activity
- Claude idle time

## Key Behavioral Correction

This is the most important revision to the earlier concept:

- the pet must **not** use user typing in the chat bar as the typing animation trigger
- the pet typing animation should represent **Claude typing / Claude working**
- once the user presses Enter and the chat bar disappears, the pet should **not** immediately sleep if Claude is still answering
- the pet should transition to sleep only **after Claude is done typing and has produced an answer**

So the correct high-level sequence is:

1. user opens chat bar
2. pet wakes
3. user types in chat bar, but the pet does **not** switch to typing just because the user is typing
4. user presses Enter and the chat bar closes
5. Claude starts responding
6. pet shows Claude typing / work-state animations
7. Claude finishes and provides an answer
8. pet transitions to idle
9. idle timer progression begins
10. eventually pet sleeps

## Idle Progression Requirement

After Claude finishes answering and the system returns to idle, the pet must follow this progression:

- `0s` to `60s`: idle
- `60s` to `120s`: headphones groove
- `120s` to `180s`: idle again
- `180s+`: sleep

The sleep state remains active until a new user action surfaces.

This means the idle loop is not one static timeout. It is a staged progression.

## Definition of User Action

The phrase “until a new action by the user is surfaced” should be interpreted as one or more of:

- opening the Claude chat bar
- focusing the Claude panel
- starting a new Claude prompt
- sending a new Claude prompt
- triggering a Claude-specific keymap
- interacting with a diff approval flow

The implementation should reset the idle progression on these events.

## Animation Mapping

The overlay should choose a state based on the strongest current condition.

Use the Clawd GIF assets directly for these states:

- `sleep` -> sleeping GIF
- `wake` -> Clawd idle GIF
- `idle` -> Clawd idle GIF
- `typing` -> typing GIF
- `reading` -> reading GIF
- `debugging` -> debugging GIF
- `cleaning` -> cleaning GIF
- `error` -> error GIF
- `diff_wait` -> notifications GIF
- `diff_approved` -> Clawd happy GIF
- `diff_rejected` -> Clawd react annoyed GIF
- `subagent` -> subagent / juggling GIF
- `headphones_groove` -> Clawd headphones groove GIF
- `happy` -> Clawd happy GIF

### Primary States

- `sleep`
- `wake`
- `idle`
- `typing`
- `reading`
- `debugging`
- `cleaning`
- `error`
- `diff_wait`
- `diff_approved`
- `diff_rejected`
- `subagent`
- `headphones_groove`
- `happy`

### Suggested Visual Meaning

- `sleep`: sleeping GIF, used when there is no active Claude work or recent interaction
- `wake`: Clawd idle GIF, used when the chat bar just opened or Claude has just become active
- `typing`: typing GIF, used when Claude is actively generating output
- `reading`: reading GIF, used when Claude is inspecting files
- `debugging`: debugging GIF, used when Claude is investigating failures, tests, traces, or logs
- `cleaning`: cleaning GIF, used when Claude is removing or reorganizing files and directories
- `error`: error GIF, used when Claude hit an error or failed task
- `diff_wait`: notifications GIF, used while diff approval is pending
- `diff_approved`: Clawd happy GIF, used when the user accepts the diff
- `diff_rejected`: Clawd react annoyed GIF, used when the user rejects the diff
- `subagent`: subagent / juggling GIF, used while subagents are actively running
- `headphones_groove`: Clawd headphones groove GIF, used during the long-idle groove state after 60 seconds
- `happy`: Clawd happy GIF, used when Claude completed successfully and the turn is done

## Priority Model

Because multiple states can overlap, the overlay should use a priority resolver.

Recommended priority from highest to lowest:

1. `error`
2. `diff_wait`
3. `diff_rejected`
4. `diff_approved`
5. `debugging`
6. `cleaning`
7. `reading`
8. `subagent`
9. `typing`
10. `happy`
11. `headphones_groove`
12. `idle`
13. `sleep`

Rationale:

- error should never be visually hidden
- diff review states should be obvious and stable
- debugging should override generic activity
- reading and cleaning are more specific than generic typing
- subagent activity should be visible when it is the dominant behavior
- headphones groove should only appear as part of the idle progression
- sleep is the base state when nothing is happening

## Event Sources In The Existing Claude Code Path

The pet should be driven from Claude-specific events, not from generic editor state.

### 1. Chat Bar Lifecycle

The chat float is created in `open_chat_float()` in [`lua/utils/claude.lua`](/home/k0d3x/dev/kodex-ide/lua/utils/claude.lua).

This is where the pet should:

- wake when the bar opens
- reposition to the top-right of the bar
- remain awake while the bar is visible
- stop counting toward sleep while user interaction is active

The submit callback in that function is where the pet should transition away from the bar lifecycle and back to Claude work / idle lifecycle.

### 2. Claude Turn Lifecycle

The stream-json dispatcher in [`lua/utils/claude.lua`](/home/k0d3x/dev/kodex-ide/lua/utils/claude.lua) already sees:

- `system.init`
- `assistant`
- `result`

This is the correct place to drive Claude-specific working animations.

Suggested mapping:

- `assistant` with `thinking` or active generation -> `typing`
- `assistant` with `tool_use` reading files -> `reading`
- `assistant` with `tool_use` cleaning files/directories -> `cleaning`
- `assistant` with `tool_use` debugging / tests / logs -> `debugging`
- `assistant` with `tool_use` subagent work -> `subagent`
- `result` success -> `happy`
- `result` failure or error text -> `error`

### 3. Diff Lifecycle

The existing diff hooks are:

- `on_diff_open()`
- `on_diff_close()`

These should drive:

- `diff_wait` while the review is pending
- `diff_approved` on acceptance
- `diff_rejected` on rejection

If the current code does not distinguish accept vs reject at close time, the pet integration will need that signal added to the diff path so it can choose the correct animation.

### 4. Idle Timers

The idle progression should begin only after Claude is done answering and the UI has returned to an idle state.

Recommended timer sequence:

- at `t = 0s`, set `idle`
- at `t = 60s`, set `headphones_groove`
- at `t = 120s`, set `idle`
- at `t = 180s`, set `sleep`

These timers should be canceled and restarted whenever the user interacts with Claude again.

## Critical Timing Semantics

The following timing interpretation is the one the implementation should preserve:

- user presses Enter
- chat bar disappears
- Claude continues responding
- pet stays in Claude work states until Claude is actually done
- only after Claude produces its answer should the pet return to `idle`
- only then should the 60/120/180-second idle progression start

This avoids the incorrect behavior where the pet sleeps immediately when the user sends the prompt.

## Suggested State Machine

The pet should have a simple internal model:

### UI States

- `sleep`
- `wake`
- `chat_open`
- `chat_closed`

### Claude Work States

- `idle`
- `typing`
- `reading`
- `debugging`
- `cleaning`
- `error`
- `subagent`
- `diff_wait`
- `diff_approved`
- `diff_rejected`
- `happy`

### Idle Progress States

- `idle_0`
- `idle_60`
- `idle_120`
- `sleep`

The implementation can collapse these into a single enum, but the state machine should preserve the conceptual separation:

- UI lifecycle
- Claude work lifecycle
- idle progression lifecycle

## Placement Rules

The pet should appear in two main places:

### When Claude Is Idle

- the bottom-right of the Claude column if the panel exists

### When Chat Bar Is Open

- top-right of the chat bar

The pet should track the float position, width, and resize behavior of the chat bar.

If the chat bar is not present:

- keep the pet in the bottom-right idle position

## Integration Strategy

Create a dedicated overlay module, for example:

- [`lua/utils/claude_pet.lua`](/home/k0d3x/dev/kodex-ide/lua/utils/claude_pet.lua)

Responsibilities:

- load animation assets
- define animation names and frame sources
- create the overlay window
- position the overlay relative to Claude UI
- switch animation state
- manage idle timers
- hide / show on lifecycle changes
- clean up resources on close or reset

Do not embed this logic directly into the panel renderer unless the final implementation is tiny. The overlay should stay independently testable.

## Suggested Module API

The reviewer / implementer can use an API like this:

```lua
pet.setup(opts)
pet.show()
pet.hide()
pet.attach_to_panel(win_id)
pet.attach_to_chat(win_id)
pet.set_state("sleep")
pet.set_state("wake")
pet.set_state("idle")
pet.set_state("typing")
pet.set_state("reading")
pet.set_state("debugging")
pet.set_state("cleaning")
pet.set_state("error")
pet.set_state("subagent")
pet.set_state("diff_wait")
pet.set_state("diff_approved")
pet.set_state("diff_rejected")
pet.set_state("happy")
pet.set_state("headphones_groove")
pet.begin_idle_progression()
pet.cancel_idle_progression()
pet.reset_idle_progression()
pet.handle_user_interaction()
pet.handle_claude_event(event)
```

## Heuristics For State Classification

Not every Claude event will map perfectly to a single asset. The implementation should classify tool output heuristically.

### Reading

Use `reading` when Claude is clearly inspecting files:

- file read tools
- file open tools
- content inspection
- path-targeted reads

### Cleaning

Use `cleaning` when Claude is reorganizing or removing things:

- delete
- rename
- move
- cleanup
- prune
- remove directory / file

### Debugging

Use `debugging` when Claude is investigating broken behavior:

- tests
- logs
- traces
- stack traces
- reproduction steps
- fix attempts
- failure analysis

### Error

Use `error` when:

- the assistant explicitly reports failure
- the tool output indicates a hard failure
- a tool call crashes or returns an error condition
- the turn ends in a failed state

### Subagents

Use `subagent` / juggling when:

- a subagent is running
- the system emits explicit subagent activity
- the task is delegated to another agent process

### Typing

Use `typing` only for Claude's own generation activity.

Important:

- do not map user typing in the chat bar to `typing`
- user typing should be a UI event, not a Claude work event

## Chat Bar Behavior

The chat bar disappearing on Enter should not cause the pet to sleep immediately.

Correct sequence:

1. user opens chat bar
2. pet wakes
3. user types
4. user presses Enter
5. chat bar disappears
6. Claude starts responding
7. pet stays in Claude work animation states
8. Claude finishes and produces an answer
9. pet returns to idle
10. idle progression begins
11. pet eventually sleeps after 180 seconds without interaction

This is the behavior the implementation must preserve.

## Suggested File Responsibilities

### `lua/utils/claude.lua`

Keep the Claude state machine here and emit pet-relevant events from:

- chat open
- chat close
- send
- assistant events
- result events
- diff open / close
- interrupt
- reset

### `lua/plugins/claude.lua`

Initialize the pet overlay module here if the plugin spec owns Claude startup.

### `lua/plugins/ui.lua`

Keep this limited to statusline / UI theme work. Do not put the pet renderer here unless there is a strong reason.

### `lua/utils/claude_pet.lua`

Own the pet overlay implementation here.

## Recommended Implementation Order

1. Prove that a GIF can render in a floating window in Ghostty.
2. Add a pet module with a simple show/hide and state switch API.
3. Hook chat open and chat close into wake / idle transitions.
4. Hook Claude turn lifecycle events into `typing`, `reading`, `debugging`, `cleaning`, `error`, `subagent`, and `happy`.
5. Add diff approval / rejection states.
6. Implement the 60 / 120 / 180-second idle progression.
7. Add repositioning and resize handling.
8. Add cleanup logic for reset / close / teardown.

## Review Questions For Another LLM

Before implementation, the reviewer should verify:

1. Can the chosen renderer display animated GIFs correctly in Ghostty?
2. Should the pet overlay be a single persistent window or recreated per state change?
3. Is the current Claude event stream enough to classify reading, cleaning, debugging, and subagent activity?
4. Do diff acceptance and rejection need distinct event signals added to the Claude diff flow?
5. Should the idle progression be reset by panel focus, or only by explicit Claude actions?
6. Does the pet need to remain visible while Claude is working but the chat bar is closed?

## Final Design Summary

The preferred design is:

- runtime GIFs
- image overlay in Neovim
- Ghostty as the terminal environment
- separate pet overlay module
- Claude state machine as the source of truth
- typing tied to Claude's output, not user input
- sleep only after Claude finishes answering and the idle progression completes
- staged idle behavior:
  - idle for 60 seconds
  - headphones groove for the next 60 seconds
  - idle again for the next 60 seconds
  - sleep after 180 seconds total

That preserves the visual intent of the Clawd assets while fitting the architecture already present in Kodex IDE.
