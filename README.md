# opencode-hyprland-popup

An Emacs frontend (popup-frame UX) for [OpenCode](https://opencode.ai) (v1.17.11+),
tuned for Hyprland. OpenCode is used purely as a backend; this package adds only the
UX layer — a floating frame where you write a prompt with Evil `:w` and watch a live
three-phase streaming display.

## Philosophy

OpenCode does its thing. This package does **not** modify OpenCode's config, permissions,
or tool behaviour. It only chose how you write prompts and how OpenCode's output is shown.

## Prerequisites

- Emacs 27.1+ (built GTK+X11 under XWayland, or pgtk). The installed build here is
  GTK+X11 under XWayland — Hyprland-specific code is guarded by
  `(eq window-system 'x)` + `(executable-find "hyprctl")`, so it no-ops elsewhere.
- `curl` on `exec-path` (used for the SSE stream).
- `evil` (the popup binds `:w` buffer-locally to send; without evil, `C-c C-c` also sends).
- `opencode` 1.17.11+ on `exec-path`, authenticated (`~/.local/share/opencode/auth.json`).
- Recommended: `(global-auto-revert-mode 1)` so Emacs auto-refreshes files OpenCode edits
  (the package ALSO reverts touched buffers itself — Phase 8 — as a safety net).

## Install

Clone the repo and add it to `load-path`:

```elisp
;; in your init.el
(add-to-list 'load-path "~/path/to/emacs-opencode/")
(require 'opencode-hyprland-popup)
(opencode-hyprland-popup-global-mode 1) ; C-c o opens, C-c h hides/restores
```

If `C-c o` is undefined after updating from an older checkout, make sure
`load-path` points at the flattened repo root, not the former
`opencode-hyprland-popup/` subdirectory.

The package spawns and owns an `opencode serve --port 0` subprocess (managed mode) and
kills it on Emacs exit. To attach to an externally-run server instead:

```elisp
(setq oc-hp-server-port 4100)          ; attach mode: no spawn, no kill on exit
```

## Hyprland window rule (title-only)

The popup frame is titled `OpenCode Prompt`. Match on the title alone — this avoids the
`Emacs`-vs-`emacs` class casing risk (on this machine Hyprland reports class `Emacs`):

```conf
# ~/.config/hypr/hyprland.conf
windowrulev2 = float,   title:^(OpenCode Prompt)$
windowrulev2 = size 650 380, title:^(OpenCode Prompt)$
windowrulev2 = center, title:^(OpenCode Prompt)$
```

As a fallback (no config edit), the package also floats the new frame right after
`make-frame` — but it targets that **specific** frame by its Hyprland window
address (resolved by matching the frame's title via `hyprctl clients -j`), via
`hyprctl dispatch setfloating address:0x…`. This is deliberate: a bare
`hyprctl dispatch setfloating` floats the *active* window, and under XWayland the
new frame's focus/title can lag `make-frame` by a few ms — so the bare form would
race and float your *original* Emacs window instead of the popup. Disable the
runtime float with `(setq oc-hp-popup-float-on-hyprland nil)`.

## Usage

- `C-c o` / `M-x opencode-hyprland-popup-prompt` — open the popup for the current
  project. If the project has sessions, choose `*new session*` or one of the
  existing project sessions; if it has none, the session picker is skipped.
- After the session choice, choose the model. The model picker reads OpenCode's
  configured providers from the running server, so custom providers and local
  credentials are reflected instead of hardcoded model names.
- `C-u M-x opencode-hyprland-popup-prompt` — create a new session immediately.
  The picker uses `completing-read`; annotations render under vertico+marginalia,
  and under plain IDO they're hidden (graceful).
- Write your prompt in the frame. With evil, `:w` SENDS the prompt as a new turn.
  Without evil, `C-c C-c` also sends.
- `C-c h` toggles the popup frame itself. From inside the popup it hides the frame
  without deleting it; from any other Emacs frame it restores that same live frame.
  It refuses to hide the last visible graphical Emacs frame, because then no Emacs
  keybinding would remain available to restore it.
- `q` or `C-c C-k` dismisses the frame; the buffer is BURIED (not killed) so re-opening
  the same session is instant (Phase 10).

## The three-phase display

After `:w` the buffer cycles through three phases per turn:

- **Phase 0** — your prompt (editable).
- **Phase 1** — below a divider, OpenCode's thinking + tool-name/args + live text deltas
  stream into an ephemeral region (continually replaced as the turn progresses).
- **Phase 2** — on `session.status` `idle`, the ephemeral region is replaced by the joined
  final answer. The buffer now reads `[prompt] / divider / [answer]`.

## Follow-ups (Phase 9)

The frame stays open. Type your follow-up BELOW the previous answer and press `:w` again.
Only the text typed after the last answer is sent (OpenCode already holds the prior turn
server-side); the buffer is wiped to `[prompt2] / divider` and then shows `[answer2]` —
NOT the stacked `[q1 a1 q2 a2]`.

## Sessions & project scope

OpenCode scopes sessions to the git worktree root (`git rev-parse --show-toplevel`), with
per-request override via the `x-opencode-directory` header (this package threads the
resolved directory through every request). If your home directory is itself a git repo,
`git init` each project dir so its worktree root becomes the project (recommended). A
single long-lived server then serves multiple projects.

## Permissions (Phase 7)

When OpenCode's turn hits a per-tool `ask` rule, the package surfaces a `y-or-n-p` IN THE
POPUP FRAME'S OWN MINIBUFFER (the reason the frame is built with `(minibuffer . t)`):
- `y` → approve once; `C-u y` → approve always (persists the rule);
- `n` → reject (the turn aborts).
The reply is POSTed as `{"response":"once"|"always"|"reject"}`.

To make OpenCode ASK for a tool, add a permission rule to your project
`./opencode.json` (or `~/.config/opencode/opencode.jsonc`):

```json
{ "permission": { "edit": "ask", "bash": "ask" } }
```

## File revert (Phase 8)

When OpenCode's `write`/`edit`/`bash`/… tools modify files on disk, the package collects
candidate paths from `tool` parts as they stream, and after the turn finalizes
(`session.status` `idle`) it reverts every live Emacs buffer visiting a touched path. With
`global-auto-revert-mode` on this is a harmless no-op; with it off, it's the only way the
buffer refreshes without a manual `M-x revert-buffer`. Toggle the safety net:

```elisp
(setq oc-hp-revert-mode nil)            ; disable explicit revert (rely on auto-revert)
```

## Customisation

| Variable | Default | Meaning |
|---|---|---|
| `oc-hp-popup-frame-title` | `"OpenCode Prompt"` | Frame title Hyprland matches. |
| `oc-hp-popup-frame-width` / `-height` | `68` / `19` | Popup frame size (chars/lines). |
| `oc-hp-popup-float-on-hyprland` | `t` | Float the new frame by its window address (title-resolved) after make-frame. |
| `oc-hp-popup-default-model` | `nil` | Optional default `provider/model` offered in the model picker, e.g. `"opencode/mimo-v2.5-free"`. |
| `opencode-hyprland-popup-global-mode` | disabled | Optional global bindings: `C-c o` open, `C-c h` hide/restore. |
| `oc-hp-server-port` | `nil` | `nil` = spawn our own server; a number = attach. |
| `oc-hp-server-password` | `nil` | Basic-auth password (`OPENCODE_SERVER_PASSWORD`). |
| `oc-hp-permission-default-yes` | `"once"` | Default yes reply (`once` or `always`). |
| `oc-hp-revert-mode` | `t` | Revert buffers touched by OpenCode after each turn. |
| `oc-hp-display-divider` | `"─── assistant ───"` | Divider between prompt and ephemeral region. |

## Testing

A keyword test harness lives in `tests/opencode-hyprland-popup-tests.el`. Batch (no quota):

```sh
emacs --batch -L <this-pkg-dir> -L <evil-elpa-dir> \
      -l tests/opencode-hyprland-popup-tests.el -f oc-hp-run-batch-tests
```

It runs three bundled batch suites — a real-`opencode serve` transport smoke test
(Phases 1-3), the Phase 9 follow-up FSM, and the Phase 10 buffer-pool tests. The
interactive scenarios (`M-x oc-hp-test-phase5-streaming`, …`-phase9-two-turn`) open the
popup and print acceptance steps to `*Messages*`; they need your real Emacs + display + a
little LLM quota. See the harness file for each scenario's setup.

## Notes & gotchas

- The package directory and every module/provide symbol is `opencode-hyprland-popup`
  (with an **L** after `hypr`: `h-y-p-r-l-a-n-d`). Several hand-off notes drop the `L`
  (`opencode-hyprand-popup` — no `L` after `hypr`), which silently fails file lookups.
- The live 1.17.11 server emits **v1** `message.part.*` events (not the v2
  `session.next.*` the dev branch schema describes); the display dispatches by
  `part.type`. The v2 hooks are wired for forward-compat.
- Targets OpenCode 1.17.11; later versions may move to v2 events / `/api/` paths.
