# RESEARCH.md — verification of the `opencode-hyprland-popup.el` brief

Built from a hands-on verification run against the user's actual machine
(2026-06-25). Each item maps to a numbered entry in the brief's §6 checklist.
**Divergences from the brief are marked ⚠ and must be agreed before coding.**

---

## 1. Tooling & versions (checklist 1, 3, 4, 8, 9)

| Check | Expected | Found | Status |
|---|---|---|---|
| `opencode --version` | 1.17.11 | **1.17.11** | ✅ exact match |
| `curl` installed | yes | `/home/linuxbrew/.linuxbrew/bin/curl` | ✅ |
| `emacs --version` | pgtk build (§3.4) | **GNU Emacs 30.2**, `/usr/bin/emacs` | ⚠ see §2 below |
| `hyprctl clients` class | `emacs` (lowercase, §3.4/§8) | **`Emacs`** (capital E) | ⚠ see §3 below |
| `git` | yes | yes | ✅ |
| Evil installed & global | yes | `evil-mode 1` global, `evil-20251108.138` in elpa | ✅ |
| `karta0807913/opencode.el` installed | maybe | **NOT installed** | ⚠ see §5 below |
| `hyprctl` (runtime float fallback) | present | present | ✅ |

Build flags for the installed Emacs (`system-configuration-features`):
`ACL CAIRO DBUS ... X11 XDBE XIM XINPUT2 XPM GTK3 ...` — and a live
`(featurep 'pgtk)` eval returns **`nil`**, `(featurep 'x)` returns **`t`**.
This is a **GTK3 + X11 build, not pgtk** — Emacs runs as an **XWayland**
client under Hyprland.

---

## 2. ⚠ Emacs is NOT a pgtk build (divergence)

The brief (§3.4) and the research report (§2a) both flag that a **pgtk**
build is "needed for clean Wayland floating." The installed Emacs is
**GTK+X11 running under XWayland**. Consequences:

- `make-frame` will produce **XWayland** toplevels, not native Wayland
  surfaces. Hyprland still manages them (window rules + dispatchers apply
  to XWayland windows), so floating **works** — but clipboard, fractional
  scaling, and IME are "flakier" per the report.
- The user's main Emacs window is *already* an XWayland window (confirmed:
  `hyprctl clients` lists it, `class: Emacs`), and they live in it daily,
  so XWayland is clearly tolerable for them.
- The frame `name` → Wayland title path the report describes (pgtk keeps
  `xdg_toplevel.title` in sync with `name`) still works via XWayland:
  XWayland exposes the GTK window title as `_NET_WM_NAME`, which Hyprland
  reads. Live evidence: the current Emacs frame title is
  `opencode-hyprland-popup-brief.md - GNU Emacs at cachyos-x8664`, derived
  from the buffer name — so title-matching will work.

**Recommendation:** proceed with the installed XWayland build; do **not**
block the project on rebuilding Emacs. Guard Hyprland-specific code with
`(executable-find "hyprctl")` AND `(eq window-system 'x)` (XWayland reports
`window-system` as `x`, not `pgtk` — verified: `pgtk` feature is nil). If
the user later switches to a pgtk build, only the guard predicate changes.
Flag for user decision: ship as-is, or ask the user to install pgtk first?

---

## 3. ⚠ Hyprland class is `Emacs`, not `emacs` (divergence)

Brief §3.4 and the report §8a both propose:

```
windowrulev2 = float, class:^(emacs)$, title:^(OpenCode Prompt)$
```

`hyprctl clients` reports the running Emacs as `class: Emacs` (capital E).
hyprlang regexes (C++ `std::regex`, ECMAScript) are **case-sensitive**, so
`class:^(emacs)$` would **fail to match** the user's actual frames. The brief
itself warns the class "might be `emacs`, `Emacs`, or `emacs-<version>`" — for
*this* machine it is `Emacs`.

**Recommendation (build-independent): match on title alone.** The popup
frame title `OpenCode Prompt` is unique to our frame, so we don't need the
class matcher at all:

```conf
# ~/.config/hypr/hyprland.conf
windowrulev2 = float,   title:^(OpenCode Prompt)$
windowrulev2 = size 90 28, title:^(OpenCode Prompt)$
windowrulev2 = center, title:^(OpenCode Prompt)$
```

As a runtime fallback (no config edit, robust against focus races), also
implement Option A from report §8d — `hyprctl dispatch setfloating` on the
active window immediately after `make-frame`:

```elisp
(when (and (executable-find "hyprctl") (eq window-system 'x))
  (call-process "hyprctl" nil 0 nil "dispatch" "setfloating"))
```

Hyprland 0.55 note: the report says 0.55 "deprecated hyprlang in favor of a
Lua config, but the legacy hyprlang syntax still works for window rules."
The user's existing config is entirely in hyprlang `windowrulev2 = ...` form
and loads cleanly on Hyprland 0.55.4, so adding more `windowrulev2` lines is
safe. Flag for user: confirm they want the static rule in `hyprland.conf`
(cleaner, persists) vs. runtime-only float (no config edit).

---

## 4. OpenCode server — verified live (checklist 2)

Started `opencode serve --port 4100`, then exercised the endpoints the
package will use:

- `GET /global/health` → `{"healthy":true,"version":"1.17.11"}` ✅
  (this is the readiness poll the brief §3.2/§7.2 wants)
- `GET /doc` → OpenAPI 3.1 document present ✅
- `GET /event` (SSE) → first line
  `data: {"id":"evt_...","type":"server.connected","properties":{}}` ✅
  matches brief §4 (first event = `server.connected`)
- `GET /session` → returns an array of session objects ✅, but the **shape
  is richer** than the brief's `[{id, title, updated, created, projectId,
  directory}]`:
  actual fields include `id, slug, projectID, directory, path, summary,
  cost, tokens, title, agent, model, ...`
  - the project field is **`projectID`** (camelCase, capital `ID`), not
    `projectId` (brief §4) — code that reads it must use the right key.
  - there is a `slug` (kebab-case human title) in addition to `title`.

**Not verified empirically (requires a live, quota-burning turn):** the
per-turn event taxonomy in brief §4 (`session.next.reasoning.*`,
`session.next.tool.called`, `session.next.text.ended`, `session.status`
idle, `permission.asked`). The brief states these come from reading the
OpenCode source at 1.17.11 / dev HEAD on 2026-06-25, and the user's
installed version matches. **Verification plan:** during Phase 5 testing,
send one short prompt and log the raw event stream to confirm the
`session.next.*` vs v1 `message.part.*` split before wiring the display
state machine to specific event names. Flag as a known risk for Phase 5.

---

## 5. ⚠ Session scope = git worktree root, but the user's HOME is the worktree root (major divergence)

From `/home/muradkant/Projects/Emacs-oc`:
```
$ git rev-parse --show-toplevel   -> /home/muradkant
$ git rev-parse --git-common-dir   -> ../../.git   (= /home/muradkant/.git)
```

**The user's entire home directory is a single git repo**, and
`Emacs-oc` is *not* its own repo (no local `.git`). Per brief §3.6,
OpenCode scopes sessions to the git worktree root — so **every** popup
invoked from anywhere under `~/` would resolve to the **same** project
root `/home/muradkant` and share one session bucket. That is almost
certainly not what the user wants (a prompt about `Emacs-oc` and a prompt
about `~/Projects/some-other-thing` would land in the same scope).

**Options** (need user decision):
1. **`git init` `~/Projects/Emacs-oc`** (and any other project dir) so each
   is its own repo → worktree root becomes the project dir, matches the
   brief's intent. Cleanest, but touches the user's repo layout.
2. **Override scope per-request** via the `x-opencode-directory` HTTP
   header (brief §4 mentions this) — e.g. scope to the directory tree
   containing a `.opencode` marker or the nearest `opencode.json` /
   `.git`-boundary-of-our-choosing. Keeps the package self-contained
   without reorganizing the user's filesystem, but diverges from OpenCode's
   default scope and from brief §3.6's "we use OpenCode's sessions directly."
3. **Accept home-as-scope** and rely on the session picker (Phase 6) to
   distinguish sessions by title — the user already lives with home-as-repo.

My lean: **option 2 with a user-configurable `opencode-hyprland-popup-scope-function`**
defaulting to OpenCode's native behavior (worktree root) but overridable —
this respects "we use OpenCode's sessions directly" by default *and* gives
the user an escape hatch for the home-as-repo case. But this is a
philosophy-adjacent decision (we'd be adding a layer OpenCode doesn't have),
so I want the user's call before coding.

---

## 6. User's Emacs stack (checklist 5)

- **Config layout:** vanilla `~/.emacs.d/{early-init,init}.el` + `lisp/` for
  local packages. **No Doom, no Spacemacs, no straight.el.** Package
  management is plain `package.el` + `use-package :ensure` from MELPA+GNU.
- **Completion stack: ⚠ IDO** (`ido-mode 1`, `ido-everywhere 1`). NOT
  vertico/ivy/helm/consult/marginalia. The brief §3.6/§7 assumed
  "portable across vertico/ivy/helm/ido" and lean on `completing-read`.
  Consequence: **IDO does not render completion-metadata `:annotation-function`
  annotations** out of the box (that's a marginalia/vertico feature), so the
  session-picker annotations (title / time / msg count) the brief §3.6 wants
  will **not display** under plain IDO. Two paths:
  1. Stick with plain `completing-read` and **embed the annotation in the
     candidate string itself** (e.g. `"sync-final  · 12 msgs · 2h ago"`) so
     IDO shows it inline — works everywhere, no extra deps. Slightly less
     pretty but robust.
  2. Suggest the user enable `marginalia-mode` (or switch to vertico) for
     rich annotations. Optional, not a hard dependency.
  My lean: **option 1** (inline annotations) for zero new deps, keeping the
  package self-contained — matches the user's minimal setup. Flag for user.
- **Evil:** global, `evil-want-keybinding nil`, `evil-undo-system
  'undo-tree`. The user already defines custom ex commands
  (`:compile`, `:recompile`, `:Man`), so they are comfortable with the
  `evil-ex-define-cmd` pattern the brief §3.5 prescribes. Good.
- **No `evil-collection`**, no `evil-org`. Our popup-mode keymap is ours
  to define; we won't collide.
- **`undo-tree` is global.** Our prompt buffer will accumulate undo
  history — harmless, but the ephemeral Phase-1 region's rapid replacements
  could pollute undo history. Mitigation: wrap streaming inserts in
  `undo-tree--disable` / `(let ((buffer-undo-list t)) ...)` so streaming
  doesn't generate undo entries. Minor, to handle in Phase 5.
- **`winner-mode`** is on — irrelevant to our frame. Fine.
- **`global-auto-revert-mode`: ⚠ NOT enabled** (checklist 10). Per brief §5,
  when OpenCode's `write`/`edit`/`apply_patch` tools modify a file on disk,
  Emacs won't auto-refresh visiting buffers. Our Phase 8 must therefore
  explicitly revert touched buffers after the turn. **Recommend** the user
  enable `global-auto-revert-mode` (idiomatic, eliminates a class of
  sync bugs); if they decline, our explicit revert is the only safety net.
  Flag for user.

---

## 7. Existing AI / opencode packages in Emacs (checklist 7)

Searched `~/.emacs.d/{elpa,lisp}`:
- `elpa/` contains `evil-...` only (plus stock built-ins). **No `opencode*`,
  no `gptel`, no `ellama`, no `copilot`, no `claude-code`, no `aidermacs`.**
- `lisp/` contains `fasm-mode.el` (assembly) and `scratch-magic-polish.el`
  (a local Gemini-API scratch helper the init.el loads optionally).

So there is **no prior AI-pattern** in the user's config to mirror, and
**`karta0807913/opencode.el` is NOT installed** despite brief §3.10 leaning
on it as "70% of what we need."

### Decision needed: dependency strategy (brief §3.10)

The brief says depend on `karta0807913/opencode.el`, *or* vendor its
modules, *or* reimplement (~1.4k lines). The research report §6b already
audited it and found it solid (curl `-N` SSE, `--port 0` lifecycle,
`process-adaptive-read-buffering nil`, accumulator-buffer filter, reconnect
backoff — all the patterns we want). Three concrete paths:

| Path | What it costs | What it gains | Risk |
|---|---|---|---|
| **A. Depend on it** (`use-package` from GitHub) | user adds one recipe / manual clone into `elpa/` (it's **not on MELPA**, report §6a) | we write ~0 transport code; just the UX layer | upstream churn can break us; we can't easily patch; user must clone a non-MELPA repo into their `package.el` setup |
| **B. Vendor** its `opencode-sse.el` + `opencode-server.el` + `opencode-session.el` into our repo, edited as needed | ~600 LOC copied + maintained | full control, no external install step, matches "self-contained" | we own the maintenance; must keep license/attribution |
| **C. Reimplement** from scratch (the brief's ~1.4k LOC plan) | ~1.4k LOC | zero external code; smallest attack surface | more work; risk of bugs the reference already fixed |

My lean: **Path B (vendor)**. Reasons: (1) the user has no straight.el and
`karta0807913/opencode.el` isn't on MELPA, so "depend on it" is awkward in a
plain `package.el` setup; (2) vendoring keeps our package a single drop-in
`~/.emacs.d/lisp/` tree like their existing `fasm-mode.el`; (3) we will
likely need small tweaks (e.g. home-as-repo scope fix from §5, IDO-friendly
candidate shaping from §6) that are cleaner on owned code. **Flag for user
decision before Phase 1.** Phase 1 (SSE client) is exactly where this
bites — Path A reuses `opencode-sse.el`, Path B/C writes our own.

---

## 8. What surprised me (summary)

1. **Home directory is a git repo** → OpenCode's native session scope
   collapses to `~` for everything. (§5) — biggest functional risk.
2. **Emacs is XWayland, not pgtk** — but the user already lives in it, so
   floating our frame will work; just need the right guard predicate and a
   title-based (not class-based) window rule. (§2, §3)
3. **Hyprland class is `Emacs` (capital), not `emacs`** — the brief's
   literal regex would silently fail to match. (§3)
4. **Completion stack is plain IDO** — the brief's annotation-function
   approach won't render; inline annotations are the robust fix. (§6)
5. **No existing opencode.el 安装** — the dependency decision in §3.10 is
   real and blocks Phase 1. (§7)

## 9. What matches the brief (no change needed)

- OpenCode 1.17.11 server endpoints (`/event`, `/doc`, `/global/health`,
  `/session`) all behave as described; `server.connected` is the first SSE
  event. (§4)
- The `make-frame` + `(name . "OpenCode Prompt")` + `set-frame-name`
  mechanism and `(unsplittable . t)` / `(minibuffer . t)` parameters are
  valid; the title does propagate to the WM title Hyprland matches. (§2,§3)
- The buffer-local `evil-ex-commands` override via `copy-alist` then
  `evil-ex-define-cmd` (brief §3.5 / report §3c) is correct and is the
  idiom the user already uses for `:compile`/`:recompile`/`:Man`. (§6)
- The SSE transport choice (`make-process` + `curl -N`,
  `process-adaptive-read-buffering nil`, `utf-8-unix`, `-s`) is correct
  and matches the reference implementation. (§4)
- The comint/compile streaming-insertion pattern (process-mark, `inhibit-
  read-only`, `window-point-insertion-type t`, idle-timer coalescing) is
  the right model for the three-phase display. (report §4a)

---

## 10. Decisions to confirm with the user BEFORE Phase 1

1. **Dependency strategy** — vendor (`opencode-sse.el` etc. into our repo),
   depend on `karta0807913/opencode.el`, or reimplement? (My lean: vendor.)
2. **Home-as-repo session scope** — accept, `git init` project dirs, or add
   a configurable scope-function with the `x-opencode-directory` header?
   (My lean: configurable scope-function, default = worktree root.)
3. **Emacs pgtk vs XWayland** — proceed with the installed XWayland build
   (my lean), or ask the user to install pgtk first?
4. **Hyprland window rule** — add a static `windowrulev2 = float,
   title:^(OpenCode Prompt)$` to `hyprland.conf` (my lean), or runtime-only
   `hyprctl dispatch setfloating` after `make-frame` (no config edit)?
5. **Session-picker annotations under IDO** — inline annotations baked
   into candidate strings (my lean, zero deps), or recommend the user add
   `marginalia`/`vertico`?
6. **`global-auto-revert-mode`** — recommend the user enable it (my lean),
   or rely solely on our explicit Phase-8 revert?
7. **Project name / file layout** — single file `opencode-hyprland-popup.el`
   in `~/.emacs.d/lisp/`, or multi-file (matching what we'd vendor)?

## 11. Proposed Phase 1 (SSE client) — once §10 is agreed

Module: `opencode-hyprland-popup-sse.el` (or appropriate name per §10.7).

Scope (~150 LOC):
- `opencode-hp--sse-start URL` — `make-process` driving
  `curl -s -N -H "Accept: text/event-stream" -H "Cache-Control: no-cache" URL`,
  `:connection-type 'pipe`, `:noquery t`, our filter + sentinel.
  Bind `process-adaptive-read-buffering` to `nil` around the call.
  `set-process-coding-system 'utf-8-unix 'utf-8-unix`.
  `set-process-query-on-exit-flag nil`.
- `opencode-hp--sse-stop` — `delete-process`, clear state.
- `opencode-hp--sse-filter proc string` — append to a dedicated accumulator
  buffer, scan for newlines, dispatch complete lines to a line parser,
  bulk-`delete-region` consumed prefix (the reference's O(n) optimization,
  report §6b).
- `opencode-hp--sse--process-line line` — SSE field parser
  (`event:`/`data:`/`id:`/comment/blank-line), joining multi-`data:` with `\n`.
- `opencode-hp--sse-dispatch type data` — `json-read-from-string` the data,
  then a `pcase` on `type` that for Phase 1 just **logs** each event
  (message `"[opencode-sse] %s"`). No display wiring yet — Phase 3/5.
- `opencode-hp--sse-sentinel proc event` — log open/close; reconnect hook
  stub (backoff wiring deferred to a later phase).

Test plan (verifiable by the user):
1. `opencode serve --port 4100 &` (or our Phase-2 spawner once it exists).
2. `M-x opencode-hp--sse-start` with the URL; check `*Messages*` for a
   `[opencode-sse] server.connected` log line within ~1s.
3. Open a second shell, `curl -X POST .../session/:id/prompt_async` (or run
   `opencode run` in another terminal against the same server) and confirm
   the user sees `session.*` event types scrolling in `*Messages*`. This
   also **empirically verifies the event taxonomy** called out in §4 as
   unverified.
4. `M-x opencode-hp--sse-stop`; confirm the curl process is gone
   (`pgrep -fa curl`).

Phase 1 deliberately has **no Hyprland, no frame, no Evil, no display** —
it's pure transport, testable from a daemon Emacs with no UI, so the user
can verify it even before any of the UX exists.

---

## 13. Corrigenda verified against OpenCode v1.17.11 source (2026-06-25)

Cloned `https://github.com/sst/opencode` at tag `v1.17.11` and read the
canonical schema + route source. **The brief's API/event claims were
partly wrong**; these supersede them:

### 13.1 `POST /session/:id/prompt_async` body — NOT `{prompt:"..."}`
- File: `packages/schema/src/session-v1.ts:397` (`TextPartInput`)
  and `packages/opencode/src/server/routes/instance/httpapi/handlers/session.ts:309` (`promptAsync`).
- Body schema: `{ parts: Array<TextPartInput|FilePartInput|AgentPartInput|SubtaskPartInput>, ...optional }`;
  `parts` is **required**. `TextPartInput = { type:"text", text:string, id?, synthetic?, ignored?, time?, metadata? }`.
- So the correct minimal body is `{"parts":[{"type":"text","text":"<prompt>"}]}`.
  Sending `{"prompt":"..."}` → **HTTP 400** (verified live). The brief §4
  said "POST /session/:id/prompt_async" but didn't specify the body; my
  Phase 3 first draft used `{:prompt prompt}` and the live test caught it.
  Phase 3's `oc-hp-session-prompt-async` was corrected to build the
  `{:parts ((:type "text" :text prompt))}` envelope.
- Confirmed response is **204 No Content** (`HttpApiSchema.NoContent.make()`,
  handler line 326) — matches brief §4.

### 13.2 Permission reply body — NOT `{allow:bool}`
- File: `packages/opencode/src/server/routes/instance/httpapi/groups/session.ts:74`
  (`PermissionResponsePayload = {response: PermissionV1.Reply}`) and
  `packages/schema/src/permission-v1.ts:38` (`Reply = Literals(["once","always","reject"])`).
- Endpoint: `POST /session/:id/permissions/:permissionID` (path matches brief).
- Body: `{"response":"once"|"always"|"reject"}`. A `y-or-n-p` should map
  **yes→"once"** (allow this once) or "always" (if we want to persist),
  **no→"reject"**. Phase 7 will default to "once"/"reject" and expose
  `always` via prefix-arg, since "always" modifies persistent rules
  (a soft philosophy violation — see §2; we'll keep "always" optional).

### 13.3 Turn-complete signal is `session.status` with `status.type=="idle"`
- File: `packages/schema/src/session-status-event.ts:8-40`.
  `session.status` shape: `{ sessionID, status: {type:"idle"|"busy"|"retry", ...} }`.
  `session.idle` is **deprecated** (comment line 42). Phase 5 must key on
  `session.status` + `status.type=="idle"`, NOT the deprecated `session.idle`.
  Our SSE module's `oc-hp-sse-session-status-hook` is correct; the idle
  hook is kept only for forward-compat.

### 13.4 v2 session.next.* event taxonomy — full source list
- File: `packages/schema/src/session-event.ts` (read in full, 519 lines).
  Full v2 set, useful ones confirmed:
  - `session.next.text.{started,delta,ended}` — `ended` has full `text:string`; deltas are live-only (no version).
  - `session.next.reasoning.{started,delta,ended}` — `ended` has full `text:string`.
  - `session.next.tool.called` — `{tool, input, provider}` (name+args, no result). ✓ matches brief.
  - `session.next.tool.input.{started,delta,ended}` — streaming tool args (live-only for delta).
  - `session.next.tool.{success,failed,progress}` — results (we DROP these for display, per brief).
  - `session.next.step.{started,ended,failed}` — `ended` has `finish, cost, tokens, snapshot?, files?: RelativePath[]` ← **Phase 8 source for touched files**. `failed` has `error`.
  - `session.next.{prompted, prompt.admitted, context.updated, synthetic}` — prompt lifecycle.
  - `session.next.{agent.switched, model.switched, moved, retried, compaction.*, revert.*}` — auxiliary.
- The brief §4 list was accurate for the events we render; this audit
  adds `session.next.step.ended.files` as the file-revert trigger (the
  brief §3/§8 spoke of tracking via `session.next.tool.called`'s
  `input.filePath`, but `step.ended.files: RelativePath[]` is the
  server-authoritative list per turn — **switch Phase 8 to use it**).
- v1 (`message.part.*`) events live in `session-v1.ts`; the brief's
  "prefer v2 over v1" is right. Our SSE filter dispatches by the JSON
  `type` field, so both pass through; Phase 5 will register *v2* handlers.

### 13.5 SSE payload envelope
- Live-confirmed (Phase 1 test): the server wraps events as
  `data: {"payload":{"id":"evt_...","type":"...","properties":{...}}}` with
  bare `data:` lines (no `event:` field on the wire). Our SSE parser
  correctly resolves the type from `payload.type` and properties from
  `payload.properties` (instance envelope `{type, properties}` is the
  inner payload). This matches report §6b's "two envelope shapes" claim.

### 13.7 ⚠ LIVE 1.17.11 EMITS V1 `message.part.*` EVENTS, NOT v2 `session.next.*`

**This is the single biggest finding** from the live end-to-end send and
supersedes RESEARCH §13.4 / the brief §4. We sent a real prompt to the
installed server and observed its SSE stream verbatim:

- The server emits **v1** events: `message.part.updated`, `message.part.delta`,
  `message.updated`, `session.updated`, `session.status`, `session.idle`,
  `session.diff`, `project.updated`. **None** of the v2 `session.next.*`
  types fired on 1.17.11. The brief's "Prefer v2 over v1" is correct as a
  schema-reader intuition but **wrong for what this version actually
  streams** — v2 is on `dev` HEAD; v1.17.11 still emits v1.
- **V1 event shapes verified live** (this is the data model Phase 5 wires):
  - `message.part.updated` → `{:sessionID, :part <part-obj>, :time <ms>}`
  - `message.part.delta`    → `{:sessionID, :messageID, :partID, :field "text", :delta "<chunk>"}`
  - `session.status`        → `{:sessionID, :status {:type "busy"|"idle"|"retry", ...}}`
  - `session.idle`          → `{:sessionID}` (deprecated; still fires in 1.17.11)
- **Part `:type` values observed** in a no-tool turn: `step-start`,
  `text`, `step-finish`. (Source `session-v1.ts` and the rendered message
  list confirm additional types: `reasoning`, `tool`, `file`.) So Phase 5
  dispatches by `part.type`, not by event name.
  - `step-start`: `:snapshot` (workspace-hash)
  - `text`: `:text` (the answer chunk — empty on first appearance, grows;
    has `:time.end` when complete)
  - `step-finish`: `:reason "stop"`, `:cost`, `:tokens`, `:snapshot`
  - `tool` (per source): `:tool`, `:input`, plus result on later updates
- **`session.status` `:busy` fires several times**; the turn is complete
  only when `:idle` arrives (or `session.idle`). Phase 5 keystones on `idle`.
- **`/session/:id/message`** returns message plists with `:role` (=nil
  in our test — likely a quirk of the response shape — and `:parts` =
  a list of part plists identical to the streaming ones).

**Implication for Phase 5:** register handlers on
`oc-hp-sse-message-part-updated-hook` (already wired in Phase 1 SSE) and
on `oc-hp-sse-session-status-hook`. The `message.part.delta` SSE event
type IS already mapped to `oc-hp-sse-message-part-updated-hook` in our
module — handlers branch on `(plist-get event :type)` to distinguish
`.updated` vs `.delta`.

The v2 hooks (`oc-hp-sse-session-next-*`) added in Phase 1 remain wired
for forward-compatibility (dev branch emitted these) but Phase 5 does
NOT depend on them for 1.17.11. If/when the user upgrades to a v2-emitting
version, Phase 5 only needs to register the v2 handlers alongside — the
buffer-mutation machinery is event-shape-agnostic.
- Live OpenAPI spec at `http://<host>:port>/doc` (verified). Top-level
  path prefixes in the spec: `/session`, `/session/status`, plus
  `/api/session/...` (newer effect HttpApi namespace). The **path used
  by brief §4 and Phase 3** — `/session/:id/...` — is the canonical
  public one; the `/api/...` paths are the newer namespace sharing
  `:sessionID` parameter naming. We use `/session/:id/...` (matches
  what the official SDK is moving to and what's in brief).

1. **Session scope** → user will `git init` each project dir (e.g.
   `~/Projects/Emacs-oc`), so OpenCode's native worktree-root scope then
   resolves to the project dir. Package uses OpenCode's native scope
   unchanged; no scope-function layer added (respects "use OpenCode's
   sessions directly").
   - **Open follow-up:** should `git init` `~/Projects/Emacs-oc` *now*?
     (It's currently tracked under `~/.git`; initializing here detaches
     it from the home repo so OpenCode scopes sessions to this dir and
     our files aren't tracked by the home repo.) Confirm in Phase 1.
2. **Dependency strategy** → vendor `karta0807913/opencode.el`'s transport
   modules, edited as needed.
3. **Emacs build / Hyprland** → proceed with the installed XWayland build
   + a static hyprland.conf rule on **title only**:
   `windowrulev2 = float, title:^(OpenCode Prompt)$` (plus size/center).
   Guard Hyprland runtime calls with `(eq window-system 'x)` AND
   `(executable-find "hyprctl")`. Runtime `hyprctl dispatch setfloating`
   as a fallback if no static rule.
4. **Session-picker annotations** → emit completion-metadata
   `:annotation-function` (the rich path); recommend the user install
   `marginalia` (and optionally `vertico`) to render them. Pick a graceful
   no-annotation default under plain IDO.
5. **File revert** → user enables `global-auto-revert-mode` in init.el;
   Phase 8 STILL implements explicit revert of touched buffers (harmless
   redundancy, defensive if mode ever off).
6. **File layout** → standalone package dir in the repo:
   `~/Projects/Emacs-oc/opencode-hyprland-popup/`, `load-path`-added from
   init.el.

### Prefix choice (proposed)

Vendored/own Elisp symbols use the prefix **`oc-hp-`** (OpenCode Hyprland
Popup). Rationale: short, distinctive, no collision with `opencode-...`
(the reference package's prefix), avoids double-loading clashes if the
user ever installs the real `opencode.el`. Confirm in Phase 1.

Brief is **~90% accurate** for this machine. Four real divergences need
your call before code: (1) your **home is a git repo** so OpenCode would
scope all sessions to `~`; (2) Emacs is **XWayland not pgtk** (works, but
the guard and window-rule must be title-based); (3) Hyprland class is
**`Emacs`** not `emacs` (use `title:`-only rule); (4) you use **plain IDO**
(no vertico/marginalia) so session-picker annotations must be inline.
Plus a strategy choice: vendor `karta0807913/opencode.el`'s transport
modules (my lean) vs depend on it vs reimplement. Reply to §10 and I'll
write Phase 1.
---

## 14. Phase 9 + 10 verification (2026-06-26, batch, no quota)

### 14.1 Phase 9 — follow-up prompt extraction + buffer wipe
Implemented in `opencode-hyprland-popup-display.el` (`oc-hp-display--finalize`
anchors `oc-hp-popup-answer-end` at the end of the finalized answer) and
`opencode-hyprland-popup.el` (`oc-hp-popup--current-prompt-text` branches on
`oc-hp-popup-phase`; `oc-hp-popup-send` wipes to `[prompt2]` before reopening
the divider and refuses sends while phase 1). Verified live in `--batch` by
`oc-hp-phase9-test.el`: 9/9 checks pass — turn1 finalizes with the answer-end
marker set, a follow-up `:w` extracts ONLY `prompt2` (text after the marker),
the buffer wipes to `[prompt2]`, phase resets to 0, a first turn returns the
whole buffer, and a phase-1 send is refused.

### 14.2 Phase 10 — buffer pool (bury, don't kill)
Already correct from Phase 4 (`oc-hp-popup-quit` buries; `--ensure-buffer`
reuses via `--live-buffer` then `get-buffer-create`). Confirmed no code change
was needed. `oc-hp-phase10-test.el`: 7/7 checks pass — reuse-same-id → `eq`
buffer; distinct ids → distinct coexisting buffers; `quit` keeps the buffer
live (buried, not killed); re-open after quit reuses the SAME buried buffer
and its preserved content. Multiple session popup buffers coexist in the pool
(one `*opencode-prompt<ses_id>*` per session), so a prefix-arg picker swap
leaves the original session's buffer buried-but-alive ready to re-open.

### 14.3 Batch transport smoke test (Phases 1-3 regression)
`oc-hp-smoke.el` spawns a real `opencode serve` (Phase 2), connects the
`/global/event` SSE stream (Phase 1), and confirms `server.connected` arrives
within 10s — PASS. The Phase 6/7/8 require-chain loads cleanly. Teardown
leaves no orphan `opencode serve` / `curl` processes and port 4096 is freed.
The full byte-compile of all 8 modules stays clean (exit 0, no warnings).

### 14.4 ⚠ The `hyprland` (with `l`) spelling trap
The package dir and all module / provide symbols are `opencode-hyprland-popup`
(h-y-p-r-l-a-n-d). The handoff text and one's own retyping reflex both tend to
silently drop the `l` after `hypr` (`opencode-hyprand-popup`), which then
`read`/`edit` "File not found" or `find-file` an empty buffer (making
`check-parens` appear to pass trivially). Confirming the exact bytes from a
`ls`/`grep` result before every read/edit, and/or cmdbinding a shell var
(`F=$(ls *.el)`), defeats the trap. It bit this session twice in scratch
test scripts.
