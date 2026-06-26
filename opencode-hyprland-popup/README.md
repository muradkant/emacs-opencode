# opencode-hyprland-popup

An Emacs frontend (popup-frame UX) for [OpenCode](https://opencode.ai) (v1.17.11+),
tuned for Hyprland. OpenCode is used purely as a backend; this package adds only the
UX layer — a floating frame where you write a prompt with Evil `:w` and watch a live
three-phase streaming display. See `RESEARCH.md` (repo root) for the design audit.

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

Vendor the package dir onto `load-path` and require it:

```elisp
;; in your init.el
(add-to-list 'load-path "~/.emacs.d/lisp/opencode-hyprland-popup/")
(require 'opencode-hyprland-popup)
(global-set-key (kbd "C-c o") #'opencode-hyprland-popup-prompt)
```

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
windowrulev2 = size 90 28, title:^(OpenCode Prompt)$
windowrulev2 = center, title:^(OpenCode Prompt)$
```

As a fallback (no config edit, robust against focus races), the package also runs
`hyprctl dispatch setfloating` on the new frame right after `make-frame`. Disable it with
`(setq oc-hp-popup-float-on-hyprland nil)`.

## Usage

- `M-x opencode-hyprland-popup-prompt` (or your key) — open the popup for the current
  project. Default: continue the most-recent session for that project (or create one).
- `C-u M-x opencode-hyprland-popup-prompt` — show a session picker (Phase 6) first.
  First candidate is `*new session*`. Annotations render under vertico+marginalia;
  under plain IDO they’re hidden (graceful).
- Write your prompt in the frame. With evil, `:w` SENDS the prompt as a new turn.
  Without evil, `C-c C-c` also sends.
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
`git init` each project dir so its worktree root becomes the project (recommended — see
RESEARCH §5). A single long-lived server then serves multiple projects.

## Permissions (Phase 7)

When OpenCode's turn hits a per-tool `ask` rule, the package surfaces a `y-or-n-p` IN THE
POPUP FRAME'S OWN MINIBUFFER (the reason the frame is built with `(minibuffer . t)`):
- `y` → approve once; `C-u y` → approve always (persists the rule);
- `n` → reject (the turn aborts).
The reply is POSTed as `{"response":"once"|"always"|"reject"}` (verified RESEARCH §13.2).

To make OpenCode ASK for a tool, add a permission rule to your project
`./opencode.json` (or `~/.config/opencode/opencode.jsonc`):

```json
{ "permission": { "edit": "ask", "bash": "ask" } }
```

## File revert (Phase 8)

When OpenCode's `write`/`edit`/`bash`/… tools modify files on disk, the package collects
candidate paths from `tool` parts as they stream, and after the turn finalizes
(`session.status` `idle`) it reverts every live Emacs buffer visiting a touched path. With
`global-auto-revert-mode` on this is a harmless no-op; with it off, it’s the only way the
buffer refreshes without a manual `M-x revert-buffer`. Toggle the safety net:

```elisp
(setq oc-hp-revert-mode nil)            ; disable explicit revert (rely on auto-revert)
```

## Customisation

| Variable | Default | Meaning |
|---|---|---|
| `oc-hp-popup-frame-title` | `"OpenCode Prompt"` | Frame title Hyprland matches. |
| `oc-hp-popup-frame-width` / `-height` | `90` / `28` | Popup frame size (chars/lines). |
| `oc-hp-popup-float-on-hyprland` | `t` | Run `hyprctl dispatch setfloating` after make-frame. |
| `oc-hp-popup-default-model` | `nil` | Optional model id for new sessions. |
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
little LLM quota. See the harness file for each scenario’s setup.

## Notes & gotchas

- The package directory and every module/provide symbol is `opencode-hyprland-popup`
  (with an **L** after `hypr`: `h-y-p-r-l-a-n-d`). Several hand-off notes drop the `L`
  (`opencode-hyprand-popup` — no `L` after `hypr`), which silently fails file lookups (RESEARCH §14.4).
- The live 1.17.11 server emits **v1** `message.part.*` events (not the v2
  `session.next.*` the dev branch schema describes); the display dispatches by
  `part.type` (RESEARCH §13.7). The v2 hooks are wired for forward-compat.
- Targets OpenCode 1.17.11; later versions may move to v2 events / `/api/` paths.
