# opencode-hyprland-popup

An Emacs popup for [OpenCode](https://opencode.ai), tuned for Hyprland. Write a
prompt with Evil's `:w`, watch thinking, tools, and text stream in place, then
continue in the same session without leaving the editor.

The package owns presentation, not policy: it neither rewrites OpenCode's
configuration nor changes its permissions or tool behaviour.

## Requirements

- Emacs 27.1+ with graphical frames (pgtk or GTK/X11 under XWayland)
- `curl` and OpenCode on `exec-path`
- an authenticated OpenCode installation (tested with 1.17.11)
- Evil for `:w`; without Evil, `C-c C-c` sends

Hyprland integration is guarded by an X window system plus `hyprctl`; elsewhere
it becomes an ordinary Emacs frame. `global-auto-revert-mode` is recommended,
though the package also refreshes buffers touched by OpenCode after each turn.

## Install

```sh
git clone https://github.com/muradkant/emacs-opencode.git
```

Add the repository root to `load-path`:

```elisp
(add-to-list 'load-path "~/path/to/emacs-opencode")
(require 'opencode-hyprland-popup)
(opencode-hyprland-popup-global-mode 1)
```

The global mode binds `C-c o` to open and `C-c h` to hide or restore the popup.
If an older installation leaves `C-c o` undefined, remove its former nested
directory from `load-path`; the modules now live at the repository root.

By default the package starts `opencode serve --port 0`, owns that process, and
stops it with Emacs. To attach to an existing server instead:

```elisp
(setq oc-hp-server-port 4100)
```

## Use

1. Run `C-c o` or `M-x opencode-hyprland-popup-prompt` from a project buffer.
2. Choose an existing project session or `*new session*`. With no existing
   session, the picker skips itself. A prefix argument (`C-u`) creates a new
   session immediately.
3. Choose a model. Candidates come from the running server, so configured,
   custom, and locally authenticated providers appear without hardcoding.
4. Write the prompt and press `:w` or `C-c C-c`.

The buffer moves through one readable sequence:

```text
your prompt
─── assistant ───
live reasoning, tools, and text  →  final answer
```

When OpenCode becomes idle, the live region is replaced by the joined answer.
Type a follow-up below it and send again: only the new text is submitted, the
buffer becomes the new prompt and answer, and OpenCode retains the full session
history server-side.

`C-c h` hides the popup without destroying its live buffer and restores the
same frame from elsewhere. It refuses to hide the last visible graphical Emacs
frame, which would strand the restore binding. `q` or `C-c C-k` dismisses and
buries the frame; reopening that session is therefore immediate.

### Project scope

Every request carries the Git worktree root in `x-opencode-directory`, allowing
one server to serve several projects safely. If your home directory is itself a
Git repository, initialize each project separately or set
`oc-hp-session-directory`; otherwise Git correctly treats the home worktree as
the scope.

### Permissions

An OpenCode `ask` rule appears in the popup's own minibuffer:

- `y` approves once;
- `C-u y` approves always and persists the rule;
- `n` rejects and aborts the turn.

For example, a project-local `opencode.json` can request confirmation for edits
and shell commands:

```json
{ "permission": { "edit": "ask", "bash": "ask" } }
```

### Edited files

The package gathers paths from streamed write, edit, and shell tool calls. Once
the turn becomes idle, it reverts every unmodified live buffer visiting a
touched path. Disable this safety net when another mechanism owns refresh:

```elisp
(setq oc-hp-revert-mode nil)
```

## Hyprland rule

The frame title is `OpenCode Prompt`; title-only matching avoids XWayland class
casing differences:

```conf
windowrulev2 = float, title:^(OpenCode Prompt)$
windowrulev2 = size 650 380, title:^(OpenCode Prompt)$
windowrulev2 = center, title:^(OpenCode Prompt)$
```

Without this rule, the package resolves the new frame's Hyprland address by
title and floats that address. It never floats whichever window happens to be
active—a race that can target the original Emacs frame under XWayland. Disable
the runtime fallback with:

```elisp
(setq oc-hp-popup-float-on-hyprland nil)
```

## Configuration

| Variable | Default | Effect |
| --- | --- | --- |
| `oc-hp-popup-frame-title` | `"OpenCode Prompt"` | Frame title and Hyprland match |
| `oc-hp-popup-frame-width` / `-height` | `68` / `19` | Size in characters and lines |
| `oc-hp-popup-float-on-hyprland` | `t` | Float the resolved frame address |
| `oc-hp-popup-default-model` | `nil` | Preferred `provider/model` in the picker |
| `oc-hp-server-port` | `nil` | Spawn a server; a number attaches instead |
| `oc-hp-server-password` | `nil` | `OPENCODE_SERVER_PASSWORD` for Basic auth |
| `oc-hp-permission-default-yes` | `"once"` | `once` or `always` for an affirmative reply |
| `oc-hp-revert-mode` | `t` | Refresh buffers touched during a turn |
| `oc-hp-display-divider` | `"─── assistant ───"` | Prompt/response divider |

## Verify

Run the deterministic state, buffer-pool, and directory-safety suites plus a
real `opencode serve` transport smoke test (no model request or quota):

```sh
./tests/run-batch.sh
```

The command exits nonzero if any suite fails. Interactive display, session,
permission, revert, and two-turn scenarios remain available through
`M-x oc-hp-test-phase5-streaming` through `M-x oc-hp-test-phase9-two-turn` after
loading `tests/opencode-hyprland-popup-tests.el`; their prompts state the exact
acceptance evidence.

The tested 1.17.11 server emits v1 `message.part.*` events. The display routes
those events by `part.type` and retains v2 hooks for forward compatibility.
