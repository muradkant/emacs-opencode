# Emacs Internals Research for an OpenCode Backend Package

All citations use the Savannah git mirror's `plain/` URLs (via the
`emacs-mirror/emacs` GitHub mirror, which mirrors the same tree), e.g.
`lisp/progmodes/compile.el` ->
https://git.savannah.gnu.org/cgit/emacs.git/plain/lisp/progmodes/compile.el .
Line numbers are from `master` at the time of writing. Package sources are
cited by GitHub raw URLs.

---

## 1. How `M-x compile` works internally

**File:** `lisp/progmodes/compile.el`
(https://git.savannah.gnu.org/cgit/emacs.git/plain/lisp/progmodes/compile.el)

### 1a. Prompting for the command

`M-x compile` runs the `compile` function
([compile.el:1875](https://git.savannah.gnu.org/cgit/emacs.git/plain/lisp/progmodes/compile.el)).
Its `interactive` form reads the command only when `compilation-read-command`
is non-nil or a prefix arg is given (lines 1903-1909):

```elisp
(interactive
 (list
  (let ((command (eval compile-command)))
    (if (or compilation-read-command current-prefix-arg)
        (compilation-read-command command)
      command))
  (consp current-prefix-arg)))
```

`compilation-read-command` (compile.el:1867) delegates to the built-in
`read-shell-command` (defined in `lisp/simple.el:4354`), with `compile-history`
as the minibuffer history:

```elisp
(defun compilation-read-command (command)
  (read-shell-command "Compile command: " command
                      (if (equal (car compile-history) command)
                          '(compile-history . 1)
                        'compile-history)))
```

`read-shell-command` is the standard minibuffer reader for shell commands
(`simple.el:4354`); it gives you file/command completion and history for free --
reuse it for any "type a shell command" prompt.

### 1b. Starting the async subprocess

`compile` finishes by calling `compilation-start` (compile.el:1915), the low-level
entry point defined at compile.el:2007. The actual process creation is at
compile.el:2190-2233:

```elisp
(if (fboundp 'make-process)
    (let ((proc
           (if (eq mode t)
               ;; comint path uses start-file-process via comint-exec
               (with-connection-local-variables
                (get-buffer-process
                 (with-no-warnings
                  (comint-exec outbuf ... shell-file-name nil
                               `(,shell-command-switch ,command)))))
             (start-file-process-shell-command
              (compilation--downcase-mode-name mode-name)
              outbuf command))))
      ...
      (set-process-sentinel proc #'compilation-sentinel)   ; :2217
      (unless (eq mode t)
        (set-process-filter proc #'compilation-filter))    ; :2221
      (set-marker (process-mark proc) (point-max) outbuf)  ; :2225
      ...
      (push proc compilation-in-progress))
  ;; Synchronous fallback (no async processes): call-process ...
  )
```

Key points:
- The non-interactive (non-comint) path uses
  `start-file-process-shell-command` (compile.el:2203), which is a wrapper that
  ultimately calls `make-process` / `start-file-process`. `make-process` is the
  modern primitive (C, `src/process.c`); `start-file-process` is the older one
  that also supports Tramp remote execution. Both return a process object.
- **The process buffer is set at creation** (`outbuf` passed to
  `start-file-process-shell-command`). Emacs associates the process with that
  buffer; the process-filter/sentinel then write into it.
- `(set-marker (process-mark proc) (point-max) outbuf)` (compile.el:2225)
  initializes the **process-mark** -- a marker in the buffer where the next
  chunk of output should be inserted. This is the central piece of streaming
  state.
- `set-process-sentinel` (compile.el:2217) registers the end-of-process handler.
- `set-process-filter` (compile.el:2221) registers the per-chunk handler.

### 1c. Streaming output into `*compilation*` in real time

The filter is `compilation-filter` (compile.el:2686). It is the canonical
"insert a process chunk into a read-only buffer" pattern:

```elisp
(defun compilation-filter (proc string)
  "Process filter for compilation buffers. ..."
  (when (buffer-live-p (process-buffer proc))
    (with-current-buffer (process-buffer proc)
      (let ((inhibit-read-only t)                       ; :2693
            ;; save-excursion doesn't use the right insertion-type for us.
            (pos (copy-marker (point) t))               ; :2695  insertion-type t => floats past inserts
            (min (point-min-marker))
            (max (copy-marker (point-max) t))
            (compilation-filter-start (marker-position (process-mark proc)))) ; :2701
        (unwind-protect
            (progn
              (widen)                                   ; :2704
              (goto-char compilation-filter-start)      ; :2705  jump to process-mark
              (if (not compilation-max-output-line-length)
                  (insert string)                       ; :2710
                (dolist (line (string-lines string nil t))
                  (compilation--insert-abbreviated-line ...)))
              (unless comint-inhibit-carriage-motion
                (comint-carriage-motion (process-mark proc) (point)))
              (set-marker (process-mark proc) (point))  ; :2718  advance the mark
              (compilation--ensure-parse (point))
              (run-hooks 'compilation-filter-hook))     ; :2721
          (goto-char pos)
          (narrow-to-region min max)
          (set-marker pos nil) (set-marker min nil) (set-marker max nil))))))
```

Notable details:
- **`inhibit-read-only`** (2693) lets the filter write into a buffer whose
  `buffer-read-only` is `t`. The compilation buffer is made read-only on setup
  (compile.el:2066-2068: `let ((inhibit-read-only t) ... )` then `(funcall mode)`
  which turns on `compilation-mode`; the buffer's `buffer-read-only` is set by
  the mode, but the filter can still write because it binds `inhibit-read-only`).
- **`copy-marker (point) t`** with insertion-type `t` (2695): the saved user
  point *floats forward* over inserted text, so a user sitting at the end of the
  buffer stays "at the end" as output streams in. (Older code used
  `insert-before-markers`; the comment at 2706-2708 explains the switch to
  `window-point-insertion-type`.)
- **`window-point-insertion-type`** (set to `t` buffer-locally at compile.el:2474)
  is the modern, per-window mechanism: it makes each window's `window-point`
  advance past insertions at that position, so windows tracking the end of the
  buffer scroll along with output without `insert-before-markers`.
- The filter uses `insert` (not `insert-before-markers`) at the process-mark,
  then **advances the process-mark** with `set-marker` (2718).
- `run-hooks 'compilation-filter-hook` (2721) is the extension point (the
  variable is declared at compile.el:88).

### 1d. Error parsing (brief)

After inserting, `compilation--ensure-parse` (compile.el:2720) lazily runs the
regexps in `compilation-error-regexp-alist` (compile.el:794), backed by
`compilation-error-regexp-alist-alist` (compile.el:215). Matching lines get
`compilation-error` text properties so `next-error`/`compile-goto-error`
(compile.el:2932) can jump to source. For an OpenCode package you can ignore
this -- there are no "compiler errors" to jump to.

### 1e. Buffer-local state vs. process state

Buffer-local state (set up in `compilation-start`, compile.el:2114-2159):

| Variable | Line | Purpose |
|---|---|---|
| `compilation-directory` | 2114 | dir where compile was invoked |
| `compilation-environment` | 2115 | env vars for the process |
| `compilation-search-path` | 2116 | dirs to search for source files |
| `compilation-arguments` | 2157 | `(command mode name-function highlight-regexp)` -- used by `recompile` |
| `compilation--start-time` | 1997 | start time for duration message |
| `window-point-insertion-type` | 2474 | `t`, so windows scroll with output |
| `mode-line-process` | 2207 | shows `:run`/`:exit` in the mode line |

Process state (held by the process object + its markers):
- the **process-mark** (`process-mark proc`) -- a marker in the buffer, advanced
  by the filter. This is the single source of truth for "where to insert next."
- `(process-buffer proc)` -- the output buffer.
- `compilation-in-progress` (global list, compile.el:2233) -- all running compiles,
  used for the global mode-line indicator.

So: **the buffer owns the human-visible state and the insertion point; the
process object owns the connection and the process-mark.** When the process
dies the buffer stays (so you can read the log).

### 1f. Knowing when the process is finished

`compilation-sentinel` (compile.el:2665) is the `set-process-sentinel` handler.
A sentinel is called whenever the process changes state; it checks
`(memq (process-status proc) '(exit signal))` (2667) and, on termination, calls
`compilation-handle-exit` (compile.el:2615) which writes the
`"Compilation finished at ..."` line, updates `mode-line-process`, and runs
`compilation-finish-functions` (compile.el:2662):

```elisp
(defun compilation-sentinel (proc msg)
  (if (memq (process-status proc) '(exit signal))
      (unwind-protect
          (let ((buffer (process-buffer proc)))
            (if (null (buffer-name buffer))
                (set-process-buffer proc nil)
              (with-current-buffer buffer
                (compilation-handle-exit (process-status proc)
                                         (process-exit-status proc)
                                         msg))))
        (setq compilation-in-progress (delq proc compilation-in-progress))
        (compilation--update-in-progress-mode-line)
        (delete-process proc))))
```

This is the exact pattern to copy for an OpenCode package: sentinel -> check
status -> write a footer into the buffer -> run a finish hook -> `delete-process`.

---

## 2. Floating window options for an Emacs popup buffer

### 2a. Separate frame via `make-frame`

**File:** `lisp/frame.el`
(https://git.savannah.gnu.org/cgit/emacs.git/plain/lisp/frame.el)

`make-frame` (frame.el:1019) creates a new top-level OS window. It takes an
**alist** of frame parameters (not keyword args); the docstring (1023-1041)
documents `name`, `width`, `height`, `minibuffer`, `display`, `terminal`, etc.

```elisp
(defun make-frame (&optional parameters)
  "Return a newly created frame displaying the current buffer.
Optional argument PARAMETERS is an alist of frame parameters for
the new frame.  Each element of PARAMETERS should have the
form (NAME . VALUE), for example:
 (name . STRING)        The frame should be named STRING.
 (width . NUMBER)       The frame should be NUMBER characters in width.
 (height . NUMBER)      The frame should be NUMBER text lines high.
 (minibuffer . t)       The frame should have a minibuffer. ..."
  ...)
```

Your proposed parameter set is valid (these are all real frame parameters,
documented in the Elisp manual node "Frame Parameters"):

```elisp
(make-frame
 '((minibuffer  . t)
   (width       . 80)
   (height      . 24)
   (name        . "OpenCode Prompt")   ; <-- Hyprland matches this title
   (unsplittable . t)                  ; frame can't be split -> our buffer fills it
   (auto-raise  . t)                   ; raise on selection
   (visibility  . t)))                 ; visible immediately
```

Useful extras for a popup editor frame:
- `(undecorated . t)` -- drop the OS title bar/borders (cleaner popup).
- `(no-other-frame . t)` -- `other-frame` skips it.
- `(tab-bar-lines . 0)`, `(tool-bar-lines . 0)`, `(menu-bar-lines . 0)`,
  `(vertical-scroll-bars . nil)` -- strip chrome.
- `(user-position . t)` + `(left . X)` + `(top . Y)` for explicit placement.

**Setting the title from Elisp:** `set-frame-name` (frame.el:2128) calls
`modify-frame-parameters` to set the `name` parameter:

```elisp
(defun set-frame-name (name)            ; frame.el:2128
  (interactive ...)
  (modify-frame-parameters (selected-frame)
                           (list (cons 'name name))))
```

So you can name the frame at creation (`(name . "OpenCode Prompt")`) **or**
rename it later with `(set-frame-name "OpenCode Prompt")`. Hyprland matches the
title against this value -- see section 8.

**Wayland/Hyprland behavior:** each `make-frame` call produces a **new
top-level Wayland surface** (an `xdg_toplevel`), so Hyprland window rules apply
to it just like any other window. On Wayland you should run a **`pgtk` (pure
GTK) build of Emacs** (`./configure --with-pgtk`); the regular GTK build runs
under XWayland and `make-frame` will create XWayland windows (which mostly
work but are not first-class Wayland citizens -- clipboard, fractional scaling,
and input methods are flakier).

**Deleting the frame after `:w`:** call `delete-frame` on it (and let the
prompt buffer be killed or buried). `delete-frame` refuses to delete the last
frame; guard against that:

```elisp
(defun opencode-prompt--close (frame)
  "Delete FRAME unless it's the only one."
  (when (and (frame-live-p frame) (> (length (frame-list)) 1))
    (let ((buf (window-buffer (frame-root-window frame))))
      (delete-frame frame)
      (when (buffer-live-p buf) (kill-buffer buf)))))
```

(`delete-window` is irrelevant here -- a frame made with `(unsplittable . t)`
has exactly one window, so `delete-frame` is the right call.)

### 2b. `posframe` package (child frame, WM-agnostic)

**Source:** https://github.com/tumashu/posframe (raw:
https://raw.githubusercontent.com/tumashu/posframe/master/posframe.el)

A posframe is a **child frame** -- an Emacs frame with `parent-frame` set to
another frame, embedded inside the parent. Because it lives inside the parent
Emacs frame, it is **compositor-agnostic**: it is *not* a separate Wayland/X11
toplevel, so Hyprland never sees it and no window rules are needed. On Wayland
it works in **pgtk** builds (child frames are supported there).

Key API (posframe.el):
- `posframe-show` (posframe.el:142) -- `cl-defun` with `&key` including
  `:string`, `:position`, `:poshandler`, `:width`, `:height`, `:min-width`,
  `:max-width`, `:font`, `:foreground-color`, `:background-color`,
  `:border-width`, `:internal-border-width`, `:initialize`, `:timeout`,
  `:refresh`, **`:accept-focus`** (line 177), `:hidehandler`, `:override-parameters`.
- `posframe-hide` (posframe.el:1128) -- hide without destroying (fast; reuse next time).
- `posframe-delete` (posframe.el:1195) -- destroy the frame and kill its buffer
  (slow to recreate; prefer `posframe-hide`).
- `posframe-delete-all`, `posframe-hide-all`.

Internals: `posframe-show` ultimately calls `make-frame` with a `parent-frame`
parameter (posframe.el:719-759), e.g.:

```elisp
(setq-local posframe--frame
            (make-frame
             `(,@override-parameters
               (title . "posframe")
               (parent-frame . ,parent-frame)
               (no-accept-focus . ,(not accept-focus))
               (min-width . 0) (min-height . 0)
               (border-width . 0)
               (internal-border-width . ,border-width)
               (child-frame-border-width . ,border-width)
               (vertical-scroll-bars . nil) (horizontal-scroll-bars . nil)
               (menu-bar-lines . 0) (tool-bar-lines . 0) (tab-bar-lines . 0)
               (unsplittable . t) (no-other-frame . t)
               (undecorated . ,(or (display-graphic-p) ...))
               (visibility . nil)
               (minibuffer . ,(minibuffer-window parent-frame))
               ...)))
```

Notes from the source:
- `:accept-focus` defaults to **nil**; the docstring (posframe.el:351-352) warns:
  *"When ACCEPT-FOCUS is non-nil, posframe will accept focus. be careful, you may
  face some bugs when set it to non-nil."* For an **editable** popup you must set
  `:accept-focus t`, accepting the caveat.
- `posframe-mouse-banish-function` (posframe.el:53) lets you move the mouse out
  of the way (the `posframe-mouse-banish` family).
- `x-gtk-resize-child-frames` / `posframe-gtk-resize-child-frames` (posframe.el:115)
  controls GTK's sometimes-buggy child-frame resizing.

Why it's the de-facto popup standard: `lsp-ui-doc`, `corfu-doc`/`corfu-popup`,
`vertico-posframe`, `ivy-posframe`, `which-key-posframe`, `company-posframe`,
`flycheck-posframe`, `transient-posframe` all build on it.

Limitations for our use case:
- Child frames can be **glitchy on some pgtk versions** (focus stealing,
  resizing lag, input-method issues).
- An **editor** (multi-line, arbitrary size, evil-mode) posframe is unusual --
  posframe is designed for tooltips/echo areas. `:accept-focus t` is required
  and is the explicitly-warned-about path.

### 2c. Comparison and recommendation for our use case

Our popup must be: (1) an **editable** buffer, (2) **arbitrary size** (it's an
editor, not a tooltip), (3) driven by **evil `:w`**, (4) **dismissed on send**.

| Requirement | `make-frame` (separate top-level) | `posframe` (child frame) |
|---|---|---|
| Editable buffer | native, fully featured | works but `:accept-focus t` is the warned-about path |
| Arbitrary size | `(width . W) (height . H)`, resize freely | child frames resize awkwardly; `max-width`/`max-height` |
| Evil `:w` | normal evil in a normal frame | evil in a child frame is fragile (focus, minibuffer) |
| Dismiss on send | `delete-frame` | `posframe-hide`/`posframe-delete` |
| Wayland/Hyprland | needs pgtk + a window rule for the title | needs pgtk; no window rule needed |
| Minibuffer (`:` ex prompt) | own minibuffer if `(minibuffer . t)` | shares parent's minibuffer window |
| Input method / clipboard | first-class | child-frame IME quirks |

**Recommendation: use `make-frame` (a separate top-level frame), not posframe.**
Reasons:
1. It's a real editor surface -- evil, the minibuffer (for the `:` ex line),
   input methods, and clipboard all behave normally.
2. Arbitrary size + resizing is trivial and robust.
3. On Hyprland it's just another window: a one-line `windowrulev2` (or a
   `hyprctl dispatch setfloating` after creation -- see section 8) floats it cleanly.
4. `delete-frame` on `:w` is dead simple and reliable.

posframe shines for **read-only, small, transient** tooltips at point (the
"show a doc string" use case). It is the wrong tool for a sizable, evil-driven
prompt editor -- its own docs warn about `:accept-focus`, and child frames
sharing the parent's minibuffer window makes ex-mode awkward.

---

## 3. Evil mode integration for `:w`

**Files:** `evil-ex.el`, `evil-maps.el`, `evil-commands.el`, `evil-common.el`
(https://github.com/emacs-evil/evil)

### 3a. How Evil's `:` ex-mode works

- `evil-ex` (evil-ex.el:328) is the command bound to `:`. It captures the
  current buffer as `evil-ex-original-buffer` (evil-ex.el:359, buffer-local),
  opens the minibuffer with `read-from-minibuffer` (evil-ex.el:364), and on
  exit calls `evil-ex-execute` (evil-ex.el:374).
- `evil-ex-execute` parses the string with `evil-ex-parse` (evil-ex.el:378)
  using `evil-ex-grammar`, producing an expression that calls
  `evil-ex-call-command` (evil-ex.el:762).
- **Crucially, the command runs in the original buffer.** At evil-ex.el:436 the
  command/range/argument are resolved
  `(with-current-buffer evil-ex-original-buffer ...)`, and `evil-ex-call-command`
  does the final binding lookup and `(call-interactively cmd)` (evil-ex.el:791).
  So buffer-local state of the buffer you were in when you typed `:` is in
  effect when the command executes.
- Command binding lookup is `evil-ex-binding` (evil-ex.el:692) /
  `evil-ex-completed-binding` (evil-ex.el:703), which `assoc` against
  `evil-ex-commands` (evil-ex.el:307):
  ```elisp
  (defvar evil-ex-commands nil
    "Association list of command bindings and functions.")
  ...
  (defun evil-ex-binding (command &optional noerror)
    (let ((binding ...))
      (while (stringp
              (setq binding (cdr (assoc binding evil-ex-commands)))))
      ...))
  ```
  `evil-ex-commands` is a plain `defvar` (global), but because lookup happens
  in the original buffer, a **buffer-local** value is honored.

### 3b. How `:w` is defined by default

`evil-maps.el:516` binds it:
```elisp
(evil-ex-define-cmd "w[rite]" 'evil-write)
```
The `w[rite]` form is expanded by `evil-ex-define-cmd` (evil-ex.el:584) into
five entries -- `w`, `wr`, `wri`, `writ`, `write` -- all mapping to `evil-write`.
`evil-ex-define-cmd` uses `evil--add-to-alist` (evil-common.el:87), which
expands to `(setf (alist-get key evil-ex-commands nil nil #'equal) val)`.

`evil-write` is an `evil-define-operator` (evil-commands.el:3292) that saves the
buffer to its file. For a prompt buffer with **no file** it errors:
`"Please specify a file name for the buffer"` (evil-commands.el:3312). So for
our popup we **must** override `:w`.

### 3c. Overriding `:w` buffer-locally

Because `evil-ex-commands` is global and `evil--add-to-alist` mutates existing
entries **in place** via `setcdr` (evil-common.el:100), a naive
`make-local-variable` would share list structure with the global alist and
**leak the override into every buffer**. The safe pattern is to **copy the
alist first**, then redefine the command in the copy:

```elisp
(defun opencode-prompt-send (&optional _bang)
  "Send the prompt text in the current buffer to OpenCode, then close the frame."
  (interactive "P")
  (let ((text (buffer-string))
        (frame (window-frame (selected-window))))
    ;; ... post text to the OpenCode session, start the SSE stream, etc. ...
    (opencode-prompt--close frame)))     ; see section 2a for opencode-prompt--close

(defun opencode-prompt--setup-evil-write ()
  "Make `:w' send the prompt (buffer-local)."
  (require 'evil)
  ;; Copy so setcdr in evil-ex-define-cmd doesn't mutate the global alist.
  (setq-local evil-ex-commands (copy-alist evil-ex-commands))
  (evil-ex-define-cmd "w[rite]" #'opencode-prompt-send))
```

Call `opencode-prompt--setup-evil-write` from your prompt buffer's major-mode
body (after turning on `evil-local-mode` / `evil-mode`). Because `evil-ex-call-command`
runs in the original buffer (section 3a), the buffer-local `evil-ex-commands` is used,
and `:w` / `:write` now invoke `opencode-prompt-send`. `evil-ex-define-cmd`'s
`call-interactively` (evil-ex.el:791) requires the target to be a command, so
give it an `(interactive ...)` spec -- `(interactive "P")` above also lets
`:w!` pass a "bang" flag.

### 3d. Alternative bindings

If overriding `:w` feels too invasive, bind a normal key in the prompt's
mode-specific keymap (`C-c C-c`, `C-return`, `s-return`). But since the user
explicitly wants `:w`, the buffer-local `evil-ex-commands` override is the
correct Evil-idiomatic way and is well-contained (it only affects the prompt
buffer). A small nicety: also rebind `:q[uit]` / `:x[it]` to cancel, so the
user can dismiss with `:q`:

```elisp
(evil-ex-define-cmd "q[uit]"  #'opencode-prompt-cancel)
(evil-ex-define-cmd "x[it]"   #'opencode-prompt-send)
(evil-ex-define-cmd "wq"      #'opencode-prompt-send)
```

---

## 4. Real-time buffer mutation in Emacs

### 4a. The safe mutation checklist (from comint/compile)

The canonical filter is `comint-output-filter` (`lisp/comint.el:2202`). It
embodies every rule you need:

```elisp
(defun comint-output-filter (process string)
  (let ((oprocbuf (process-buffer process)))
    (when (and string oprocbuf (buffer-name oprocbuf))
      (with-current-buffer oprocbuf
        ;; 1. run preoutput filters ...
        (let ((inhibit-read-only t)                       ; comint.el:2220
              (saved-point (copy-marker (point) t)))      ; :2222 insertion-type t
          (save-restriction                               ; :2226
            (widen)                                       ; :2227 un-narrow
            (goto-char (process-mark process))            ; :2229 jump to mark
            (set-marker comint-last-output-start (point))
            (put-text-property 0 (length string) 'field 'output string)
            (insert string)                               ; :2241 insert at mark
            (set-marker (process-mark process) (point))   ; :2244 advance mark
            (unless comint-inhibit-carriage-motion
              (comint-carriage-motion comint-last-output-start (point)))
            (goto-char saved-point)
            (run-hook-with-args 'comint-output-filter-functions string) ; :2252
            ...))))))
```

The rules, in order:
1. **Guard the buffer:** `(when (buffer-live-p (process-buffer proc)) ...)`.
   Buffers can be killed while a process is still running.
2. **`with-current-buffer`** to the output buffer -- filters run in whatever
   buffer was current when Emacs scheduled them, *not* the process buffer.
3. **`let ((inhibit-read-only t))`** so you can write into a `read-only-mode`
   / `buffer-read-only` buffer (compile.el:2693, comint.el:2220).
4. **Save point with an insertion-type-t marker:**
   `(copy-marker (point) t)` -- the `t` makes the marker advance past inserted
   text, so a user sitting at the end stays at the end (compile.el:2695,
   comint.el:2222). `save-excursion` alone is *not* enough because its marker
   has insertion-type `nil`.
5. **`save-restriction` + `widen`** -- if the buffer is narrowed and the
   process-mark is outside the restriction, you'd insert in the wrong place
   (compile.el:2699-2704, comint.el:2226-2227).
6. **`goto-char (process-mark proc)`** then **`insert`** (not
   `insert-before-markers`). Modern Emacs uses `window-point-insertion-type`
   (see below) instead of `insert-before-markers`; the comment at compile.el:2706
   explicitly says they switched away from it.
7. **Advance the mark:** `(set-marker (process-mark proc) (point))` so the next
   chunk appends after this one (compile.el:2718, comint.el:2244).
8. **Restore point/narrowing** (`goto-char pos)`, `(narrow-to-region min max)`).
9. **Run hooks** for extension points (compile.el:2721, comint.el:2252).

**`window-point-insertion-type`** (a built-in, buffer-local variable; set to `t`
by comint at comint.el:744 and by compile at compile.el:2474) is the modern
mechanism: it makes each window's point advance past insertions at that
position, so windows tracking the end of output scroll automatically -- no
`insert-before-markers` needed. Set it in your chat/stream buffer:
`(setq-local window-point-insertion-type t)`.

**`read-only-mode`** for the streamed region: turn `read-only-mode` on in the
output buffer and bind `inhibit-read-only` in the filter (as above). For a
chat that mixes read-only AI output with an editable prompt area, you can also
use **text properties**: `comint` makes prompts read-only via
`(add-text-properties start end '(read-only t front-sticky (read-only)))`
(comint.el:2270-2271). This is how you keep a region non-editable without
locking the whole buffer.

**Styling:** `font-lock-mode` works in the output buffer (compile uses
`compilation-mode-font-lock-keywords`, compile.el:1861). For per-chunk styling
use `add-text-properties` / `add-face-text-property` on the inserted text, like
gptel does (see section 6). `with-silent-modifications` (comint.el:2265) avoids
thrashing the modification hooks when applying lots of properties.

**Coalescing with timers:** process filters can fire dozens of times per
second. To avoid redisplay storms, accumulate chunks and flush on an idle
timer:

```elisp
(defvar opencode--stream-timer nil)
(defvar opencode--stream-pending "")
(defun opencode--stream-filter (proc string)
  (setq opencode--stream-pending (concat opencode--stream-pending string))
  (unless opencode--stream-timer
    (setq opencode--stream-timer
          (run-with-idle-timer 0.05 nil #'opencode--stream-flush proc))))
(defun opencode--stream-flush (proc)
  (setq opencode--stream-timer nil)
  (let ((data (prog1 opencode--stream-pending
                (setq opencode--stream-pending ""))))
    (when (buffer-live-p (process-buffer proc))
      (with-current-buffer (process-buffer proc)
        (let ((inhibit-read-only t))
          (goto-char (process-mark proc))
          (insert data)
          (set-marker (process-mark proc) (point)))))))
```

`run-with-idle-timer` (subr-x) coalesces: it only fires when Emacs is idle for
the given seconds, so rapid chunks merge into one insertion/redisplay.

### 4b. How comint handles it

`comint.el` is the basis of `M-x shell`, `ielm`, `inf-*` modes, etc. The
machinery (all in `lisp/comint.el`):
- `comint-exec` (comint.el:872) starts the process and sets
  `(set-marker (process-mark proc) (point))` (comint.el:899).
- `comint-output-filter` (comint.el:2202) -- shown above -- is the process filter.
- `comint-output-filter-functions` (run at comint.el:2252) is the user hook.
- `comint-preoutput-filter-functions` lets you transform each chunk before
  insertion.
- `comint-send-string` (comint.el:2630) sends input to the process.
- The input region is delimited by `process-mark`; `comint-bol-or-process-mark`
  (comint.el:3629) jumps to it. This is the model for "editable prompt below,
  read-only transcript above."

### 4c. Markdown rendering of streamed text

Options, from heaviest to lightest:
- **`markdown-mode`** (https://github.com/jrblevin/markdown-mode) -- just turn it
  on in the output buffer; you get font-locked markdown source as it streams.
  Simplest; this is what gptel/ellama do by default. (`markdown-live-preview`
  exists -- `markdown-live-preview-export` at markdown-mode.el:8031 -- but it
  re-exports to HTML on each change via `shr`/`eww`, which is too heavy for
  live streaming.)
- **Convert markdown -> org on the fly** in an org buffer. gptel does exactly
  this: `gptel--stream-convert-markdown->org`
  (gptel-org.el:757, https://raw.githubusercontent.com/karthink/gptel/master/gptel-org.el)
  is plugged into the stream as a `:transformer` (gptel-request.el:2861).
  This gives you proper org folding/links/code blocks in a chat transcript.
- **Plain text + text properties / overlays** -- insert raw text and apply faces
  with `add-text-properties` (as gptel does with the `(gptel response
  front-sticky (gptel))` property, gptel.el:1871). Lightest; good enough if you
  only need basic emphasis and code spans.
- `orgstruct++-mode` -- lets org structure commands work inside a non-org buffer;
  not really a renderer.

For an OpenCode chat, the pragmatic choice is `markdown-mode` for the
transcript (matches what the model emits) and, optionally, gptel-style
markdown->org conversion if you target org.

---

## 5. SSE consumption in Emacs Lisp

### 5a. `url-retrieve` / `url-retrieve-synchronously` -- buffers, not streams

The `url` library accumulates the response into a process buffer as chunks
arrive (`url-http-generic-filter`, `lisp/url/url-http.el:1578`), but the
**user callback is invoked only once**, when the response is complete -- via
`url-http-activate-callback` (url-http.el:1015), called from the
end-of-document sentinel:

```elisp
(defun url-http-activate-callback ()      ; url-http.el:1015
  ...
  (apply url-callback-function url-callback-arguments))   ; :1022
```

So `url-retrieve`/`url-retrieve-synchronously` **buffer the whole body** and
fire the callback at the end. They are unsuitable for SSE, which is an
indefinite stream of `event`/`data:` blocks. (This is exactly why the existing
`opencode-sse.el` uses curl instead -- its docstring says so, section 6.)

### 5b. `make-process` + `curl -N` -- the realistic SSE client

Spawn curl as a pipe process with `--no-buffer` (`-N`) so it flushes each
chunk immediately, and drive a process filter that buffers partial lines,
dispatches complete `data:` events, and parses JSON. Minimal, runnable:

```elisp
(defvar opencode--sse-proc nil)

(defun opencode--sse-start (url)
  "Start an SSE connection to URL via curl --no-buffer."
  (opencode--sse-stop)
  (let ((process-adaptive-read-buffering nil))   ; CRITICAL: low-latency streaming
    (let* ((coding-system-for-write 'utf-8-unix)
           ;; -N  = --no-buffer (flush each chunk)
           ;; -s  = --silent
           (proc (make-process
                  :name "opencode-sse"
                  :buffer (get-buffer-create " *opencode-sse*")
                  :command `("curl" "-s" "-N"
                             "-H" "Accept: text/event-stream"
                             "-H" "Cache-Control: no-cache"
                             ,url)
                  :connection-type 'pipe
                  :noquery t
                  :filter #'opencode--sse-filter
                  :sentinel #'opencode--sse-sentinel)))
      (set-process-coding-system proc 'utf-8-unix 'utf-8-unix) ; avoid CRLF buffering
      (set-process-query-on-exit-flag proc nil)
      (setq opencode--sse-proc proc))))

(defun opencode--sse-stop ()
  (when (and (processp opencode--sse-proc)
             (memq (process-status opencode--sse-proc) '(run open stop exit)))
    (delete-process opencode--sse-proc))
  (setq opencode--sse-proc nil))

(defvar opencode--sse-event nil)   ; plist being assembled

(defun opencode--sse-filter (proc string)
  "Accumulate STRING, dispatch complete SSE lines."
  (when (buffer-live-p (process-buffer proc))
    (with-current-buffer (process-buffer proc)
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert string)
        ;; Process complete (newline-terminated) lines; keep the tail.
        (goto-char (point-min))
        (let (done)
          (while (search-forward "\n" nil t)
            (let ((line (buffer-substring-no-properties
                         (line-beginning-position 0) (1- (point)))))
              (setq line (string-trim-right line "\r"))  ; strip CR
              (opencode--sse--process-line line)
              (setq done (point))))
          (when done (delete-region (point-min) done)))))))

(defun opencode--sse--process-line (line)
  "Parse one SSE LINE; dispatch on the blank line that ends an event."
  (cond
   ((string-empty-p line)                 ; event boundary
    (when opencode--sse-event
      (let ((type (or (plist-get opencode--sse-event :type) "message"))
            (data (plist-get opencode--sse-event :data)))
        (when data (opencode--sse-dispatch type data)))
      (setq opencode--sse-event nil)))
   ((string-prefix-p ":" line) nil)        ; comment / heartbeat
   ((string-match "^event: ?\\(.*\\)" line)
    (setq opencode--sse-event
          (plist-put (or opencode--sse-event '()) :type (match-string 1 line))))
   ((string-match "^data: ?\\(.*\\)" line)
    (let ((prev (plist-get opencode--sse-event :data)))
      (setq opencode--sse-event
            (plist-put (or opencode--sse-event '())
                       :data (if prev
                                 (concat prev "\n" (match-string 1 line))
                               (match-string 1 line))))))
   ((string-match "^id: ?\\(.*\\)" line)
    (setq opencode--sse-event
          (plist-put (or opencode--sse-event '()) :id (match-string 1 line))))
   (t nil)))                               ; unknown field, ignore per spec

(defun opencode--sse-dispatch (type data)
  "Dispatch an SSE event of TYPE whose DATA is a JSON string."
  (condition-case err
      (let* ((json-object-type 'plist)
             (json-key-type 'keyword)
             (event (json-read-from-string data)))   ; parse the JSON line
        (pcase type
          ("message.updated" (opencode--on-message-updated event))
          ("session.updated" (opencode--on-session-updated event))
          ("error"           (opencode--on-error event))
          (_ (opencode--on-unknown type event))))
    (error
     (message "opencode SSE parse error (%s): %s" type (error-message-string err)))))

(defun opencode--sse-sentinel (proc event)
  (let ((e (string-trim event)))
    (unless (string-match-p "\\`open" e)
      (message "opencode SSE closed: %s" e)
      ;; ... optional reconnect logic ...
      )))
```

Three non-obvious gotchas (all solved above and confirmed by the reference
implementation in section 6):
1. **`curl --no-buffer` / `-N` is mandatory** -- without it curl blocks on its
   own stdio buffer and you get nothing until the buffer fills or the
   connection closes.
2. **`set-process-coding-system proc 'utf-8-unix 'utf-8-unix`** -- the default
   `utf-8` coding does EOL auto-detection, which can buffer data until it sees
   a line ending and *starve the filter* if the first newline is far off.
3. **Disable adaptive read buffering.** Emacs coalesces small process reads
   with increasing delay by default, which destroys SSE latency. Bind
   `process-adaptive-read-buffering` to `nil` around the `make-process` call
   (dynamic), as shown.

### 5c. `websocket.el` -- does NOT apply to SSE

`websocket.el` (https://github.com/ahyatt/emacs-websocket, README) is
"an elisp library for websocket clients to talk to websocket servers" -- it
implements the **WebSocket protocol (RFC 6455)**, with its own handshake,
frame masking, and opcodes. SSE is a completely different mechanism (plain
HTTP `text/event-stream`, unidirectional, no handshake beyond headers). Do not
use `websocket.el` for an SSE endpoint.

### 5d. Other HTTP libraries

- **`request.el`** (https://github.com/tkf/emacs-request) -- **no streaming
  support.** A grep of `request.el` for "stream" finds nothing relevant; it
  builds on `url-retrieve` and delivers the whole body to `:success`. Not
  usable for SSE.
- **`plz.el`** (https://github.com/alphapapa/plz.el, raw
  https://raw.githubusercontent.com/alphapapa/plz.el/master/plz.el) -- the
  modern curl-backed HTTP library. It **does** support streaming via a custom
  `:filter` argument (plz.el:404-411; README.org line 145; changelog line 232):
  > *"`FILTER` is an optional function to be used as the process filter for the
  > curl process. It can be used to handle HTTP responses in a streaming way."*

  Caveat for SSE: `plz-curl-default-args` is `("--silent" "--compressed"
  "--location")` (plz.el:233-240) -- it does **not** include `--no-buffer`, and
  `plz`'s `plz` function has no per-request knob to add `-N`. You'd have to
  customize `plz-curl-default-args` globally to include `"--no-buffer"`. For
  that reason, for a dedicated SSE stream a **direct `make-process` + curl**
  (as in section 5b) is simpler and more controllable than going through `plz`.
  `plz` is a great choice for the **non-streaming** HTTP API calls (POST a
  message, list sessions, etc.) where you want clean request/response + error
  handling.

**Summary:** use `plz` (or `url-retrieve`) for normal request/response API
calls; use a bare `make-process` driving `curl -N` for the SSE event stream.

---

## 6. Existing Emacs-OpenCode integrations (and patterns to crib)

### 6a. What exists

There is **no `opencode` package on MELPA** (verified against
`https://melpa.org/recipes.json` -- no `opencode*` recipe). But there are
several GitHub packages, found via GitHub search (`q=opencode+emacs`):

| Repo | Approach |
|---|---|
| **`karta0807913/opencode.el`** | **HTTP + SSE client.** Starts `opencode serve --port 0`, parses the assigned port from server logs, connects SSE via `curl -N`. Mature: chat buffer with streaming, session sidebar, CAPF, @-mentions. **Best reference.** |
| `rogsme/opencode.el` | Subprocess TUI via `vterm`/`shell-mode`. |
| `jdormit/emacs-opencode` | "OpenCode client for Emacs." |
| `shuiruge/opencode.el` | "Emacs Integration for OpenCode." |
| `colobas/opencode.el` | Ports OpenCode's tools/prompts to run *via gptel* (uses gptel as the LLM backend, not the opencode server). |
| `tninja/ai-code-interface.el` | Unified front-end supporting OpenCode, Claude Code, Codex, Copilot CLI, etc. |

### 6b. The reference architecture: `karta0807913/opencode.el`

This package is essentially the design you're building. Fetch and read:
- `opencode-sse.el` (https://raw.githubusercontent.com/karta0807913/opencode.el/main/opencode-sse.el)
- `opencode-server.el` (https://raw.githubusercontent.com/karta0807913/opencode.el/main/opencode-server.el)
- README (https://raw.githubusercontent.com/karta0807913/opencode.el/main/README.md)

**Server lifecycle** (`opencode-server.el`): spawns
`opencode serve --port 0 --print-logs` (the `--port 0` makes the OS assign a
free port), and a process filter scans stdout for the port announcement
(`opencode-server--try-parse-port`, opencode-server.el:272), storing it in
`opencode-server--port`. Then it polls `GET /global/health` until healthy
(`opencode-server-health-check`, opencode-server.el:333, using
`url-retrieve`/`url-retrieve-synchronously`).

**SSE transport** (`opencode-sse.el`): the single most useful file to crib.
- `opencode-sse-connect` (opencode-sse.el:419) -- docstring:
  *"Uses `curl --no-buffer' for true streaming (url.el buffers responses)."*
  It builds `("curl" "-s" "-N" "-H" "Accept: text/event-stream" "-H"
  "Cache-Control: no-cache" ... <url>)`, calls `start-process`, then
  `set-process-filter #'opencode-sse--filter` (line 445),
  `set-process-sentinel #'opencode-sse--sentinel` (446),
  `set-process-query-on-exit-flag nil` (447),
  `set-process-coding-system 'utf-8-unix 'utf-8-unix` (452), and binds
  `process-adaptive-read-buffering` to `nil` (line 426) -- confirming all three
  gotchas from section 5b.
- `opencode-sse--filter` (opencode-sse.el:361) -- uses a dedicated **accumulator
  buffer** for O(1) append (gap buffer moves the gap to the end), only scans
  for newlines when the new chunk actually contains one, and does a single
  bulk `delete-region` of consumed lines (avoids O(k*n) per-line deletes). This
  is a nice optimization over the simple marker approach in section 5b.
- `opencode-sse--process-line` (opencode-sse.el:219) -- the SSE line parser
  (`event:`/`data:`/`id:`/comment/blank-line-dispatch), exactly the SSE spec.
  Multiple `data:` lines are joined with `\n`.
- `opencode-sse--parse-event` (opencode-sse.el:282) -- `json-read-from-string`
  on the data, handling OpenCode's two envelope shapes
  (`{directory,payload:{type,properties}}` global vs `{type,properties}`
  instance).
- `opencode-sse--sentinel` (opencode-sse.el:404) -- schedules reconnect with
  backoff; a heartbeat timer detects stale connections.

**HTTP API calls** use `url-retrieve` (opencode-server.el:342,
`url-retrieve-synchronously` at :355 and :497), reading the body from
`url-http-end-of-headers` to `(point-max)` and `json-read-from-string`-ing it.
So the split is: **`url`/`plz` for request-response, `curl -N` subprocess for
SSE.**

### 6c. Cribbing patterns from related AI packages

| Package | Backend | Crib what |
|---|---|---|
| `gptel` (karthink/gptel) | HTTP (OpenAI/Gemini/Anthropic/Ollama...), curl *or* url | Streaming buffer mutation, markdown->org, request FSM |
| `ellama` (s-kostyaev/ellama) | LLM backends | Chat/transcript UX |
| `claude-code` (yuya373/claude-code-emacs) | **TUI in `vterm`** (`(require 'vterm)`, claude-code.el:67; Package-Requires vterm) | Subprocess-TUI approach (the alternative to HTTP+SSE) |
| `aidermacs` / `aider.el` | subprocess | TUI/comint integration |
| `chatgpt-shell` + `shell-maker` (xenodium) | HTTP | `shell-maker` is a generic streaming-shell framework; good basis for a chat buffer |
| `copilot` (copilot-emacs) | HTTP | inline completion (less relevant) |

### 6d. How `gptel` structures request + streaming + buffer mutation

gptel is the best-documented general LLM client. Source (clone):
https://github.com/karthink/gptel -- main file `gptel.el`, curl backend in
`gptel-request.el`, org integration in `gptel-org.el`.

**Request + curl spawn** (`gptel-request.el`): `gptel-curl--get-response` (the
curl backend entry, around gptel-request.el:2810) spawns one curl process per
request:

```elisp
(let* (... (args (gptel-curl--get-args info uuid nil))
       (stream (plist-get info :stream))
       (process (make-process                  ; gptel-request.el:2819
                 :name "gptel-curl"
                 :buffer (gptel--temp-buffer " *gptel-curl*")
                 :command (cons (gptel--curl-path) args)
                 :connection-type 'pipe)))
  (with-current-buffer (process-buffer process)
    (set-process-coding-system process 'utf-8-unix 'utf-8-unix) ; :2834
    (set-process-query-on-exit-flag process nil)                ; :2835
    ...
    (if stream
        (progn (set-process-sentinel process #'gptel-curl--stream-cleanup) ; :2869
               (set-process-filter process #'gptel-curl--stream-filter))   ; :2870
      (set-process-sentinel process #'gptel-curl--sentinel))))
```

The curl args include `-N` (no-buffer) for streaming (`gptel-request.el:777`:
`"-y7200" "-Y1" "-N" "-D-"`).

**Streaming filter** (`gptel-curl--stream-filter`, gptel-request.el:2969):
classic process-mark insertion, then parse:

```elisp
(with-current-buffer (process-buffer process)
  (save-excursion
    (goto-char (process-mark process))           ; :2977
    (insert output)                              ; :2978
    (set-marker (process-mark process) (point))); :2979
  ;; find HTTP status, then gptel-curl--parse-stream extracts data: chunks
  ;; and calls the :callback with each text delta.
  ...)
```

**Buffer mutation / insertion** (`gptel-curl--stream-insert-response`,
gptel.el:1841) -- the pattern to copy for inserting a delta into the chat buffer:

```elisp
(defun gptel-curl--stream-insert-response (response info &optional raw)
  (pcase response
    ((pred stringp)
     (let ((start-marker (plist-get info :position))      ; where this response began
           (tracking-marker (plist-get info :tracking-marker))) ; advances per delta
       (with-current-buffer (marker-buffer start-marker)
         (save-excursion
           (unless tracking-marker
             (goto-char start-marker)
             (unless (or (bobp) (plist-get info :in-place))
               (insert gptel-response-separator)
               (when gptel-mode (insert (gptel-response-prefix-string)))
               (move-marker start-marker (point)))
             (setq tracking-marker (set-marker (make-marker) (point)))
             (set-marker-insertion-type tracking-marker t))   ; float past inserts
           (goto-char tracking-marker)
           (unless raw
             (when (plist-get info :transformer)
               (setq response (funcall transformer response)))
             (add-text-properties 0 (length response)
                                  '(gptel response front-sticky (gptel)) response))
           (insert response)                                  ; insert delta
           (run-hooks 'gptel-post-stream-hook)))))))
```

Key ideas:
- Two markers: a fixed `:position` (start of this AI response) and a
  `:tracking-marker` with `set-marker-insertion-type t` (gptel.el:1864) that
  always points "just after the last inserted delta" -- so each new delta is
  appended right after the previous one.
- `with-current-buffer (marker-buffer ...)` + `save-excursion` so the user's
  point elsewhere is untouched.
- `add-text-properties` tags the response text (so it can be identified,
  edited as a unit, etc.).
- A `:transformer` slot lets you pipe each delta through a converter -- gptel
  uses this for **markdown -> org** conversion in org buffers
  (`gptel--stream-convert-markdown->org`, gptel-org.el:757).
- `gptel-post-stream-hook` runs after each delta (and `gptel-pre-stream-hook`
  + `gptel-post-stream-hook` are the extension points).

So gptel's structure is: **one `make-process` curl per request** -> a
**process filter** that appends raw bytes at the process-mark and parses
`data:` SSE chunks -> a **callback** (`gptel-curl--stream-insert-response`)
that uses a **tracking marker** to append decoded text deltas into the chat
buffer, optionally through a **transformer**. This is an excellent template
for your chat buffer; the OpenCode server just changes the JSON shapes and the
event types.

---

## 7. Sessions picker UX

### 7a. `completing-read` -- the universal base

Every modern completion UI (`vertico`, `selectrum`, `ivy`, `helm`, `icomplete`,
`fido`) sits on top of the built-in `completing-read` (C primitive,
`src/minibuf.c`). **Write to `completing-read` and you get all of them for
free.** A minimal sessions picker:

```elisp
(defun opencode-select-session (sessions)
  "SESSIONS is a list of plists like (:id :title :time :messages :summary).
Return the chosen :id."
  (let* ((table (mapcar (lambda (s)
                          (propertize (plist-get s :title)
                                      'opencode-session s))
                        sessions))
         (choice (completing-read "OpenCode session: " table nil t)))
    (plist-get (get-text-property 0 'opencode-session choice) :id)))
```

### 7b. Annotations

Stash the session plist on the candidate string (as above) and supply an
annotation function via **completion metadata** (`annotation-function`).
`marginalia` (https://github.com/minad/marginalia) hooks the same metadata
mechanism for built-in categories (its annotators live in `marginalia-annotators`,
marginalia.el:91). For a custom category, supply the metadata directly via a
metadata-completion-table (built on `complete-with-action`):

```elisp
(defun opencode--session-metadata (string _table mode)
  "Completion metadata: annotate sessions with time + message count."
  (when (eq mode 'open)
    (list :annotation-function
          (lambda (cand)
            (let ((s (get-text-property 0 'opencode-session cand)))
              (when s
                (format "  %s  %d msgs  %s"
                        (opencode--format-time (plist-get s :time))
                        (plist-get s :messages)
                        (opencode--truncate (plist-get s :summary) 50))))))))
```

(`vertico` and `marginalia` will then show the annotations. If you want to
avoid the metadata-table boilerplate, see `consult--read` below.)

### 7c. `consult` -- preview + annotations in one call

`consult--read` (consult.el:2918,
https://raw.githubusercontent.com/minad/consult/master/consult.el) is "a thin
wrapper around `completing-read`" (consult.el:2925) that adds **async
candidates, live preview, narrowing, and annotations** via keyword args
(`:state`, `:annotate`, `:preview-key`, `:narrow`, `:lookup`, ...):

```elisp
(cl-defun consult--read (table &rest options &key prompt predicate require-match
   history default command keymap category initial narrow initial-narrow
   annotate add-history state preview-key sort lookup group
   inherit-input-method async-wrap) ...)
```

A consult-based sessions picker with live preview of the session transcript:

```elisp
(defun opencode-select-session (sessions)
  (let* ((candidates (mapcar (lambda (s)
                               (propertize (plist-get s :title)
                                           'opencode-session s))
                             sessions))
         (state (opencode--session-preview-state)))   ; see below
    (let* ((choice (consult--read candidates
                                  :prompt "OpenCode session: "
                                  :category 'opencode-session
                                  :state state
                                  :preview-key consult-preview-key
                                  :annotate
                                  (lambda (c)
                                    (let ((s (get-text-property 0 'opencode-session c)))
                                      (and s (format "  %d msgs . %s"
                                                     (plist-get s :messages)
                                                     (opencode--format-time (plist-get s :time))))))))
           (sel (get-text-property 0 'opencode-session choice)))
      (plist-get sel :id))))
```

The preview **state function** follows the consult convention: a function that
returns a lambda taking `(action cand)` where `action` is one of `preview`,
`exit`, `return`, `update`, `cancel`. The model is `consult--buffer-preview`
(consult.el:4817), which on `preview` switches a dedicated window to the
candidate buffer and on `exit`/`return` restores the previous buffer list:

```elisp
(defun opencode--session-preview-state ()
  "Return a consult state function that previews a session transcript."
  (let (orig-win)
    (lambda (action cand)
      (pcase action
        ('preview
         (when cand
           (let* ((s (get-text-property 0 'opencode-session cand))
                  (buf (and s (opencode--session-preview-buffer (plist-get s :id)))))
             (when buf
               (unless orig-win
                 (switch-to-buffer-other-window buf 'norecord)
                 (setq orig-win (selected-window)))
               (with-selected-window (or orig-win (selected-window))
                 (switch-to-buffer buf 'norecord))))))
        ('exit
         (when orig-win (delete-window orig-win))
         (setq orig-win nil))))))
```

(For preview you'd render the session's message history into a temporary
buffer via `opencode--session-preview-buffer`, possibly fetching it
asynchronously -- consult supports `:async` candidates via the
`consult--async-*` helpers.)

### 7d. How `consult-buffer` does it (brief)

`consult-buffer` (consult.el:5076) is the canonical multi-source picker. It
calls `consult--multi` (consult.el:5087) over a list of **sources**
(`consult-buffer-sources`), each a plist with `:name`, `:narrow`, `:category`,
`:items`, `:action`, `:state`/`:preview`, `:annotate`. Preview is driven by
`consult--buffer-preview` (consult.el:4817). For your sessions picker you
don't need multi-source; a single `consult--read` (or plain `completing-read`)
with one `:annotate` + one `:state` is enough. Use `consult--multi` only if
you want to mix "recent sessions", "current project sessions", "new session..."
as separate narrowing groups.

---

## 8. Wayland clipboard / Hyprland integration bits

### 8a. Floating a specific Emacs frame by title (static rule)

Hyprland 0.55 deprecated `hyprlang` in favor of a **Lua** config, but the
**legacy `hyprlang` syntax still works** for window rules (the current wiki
points to the 0.54 pages for it). The classic form, which is what the vast
majority of existing configs use, is:

```conf
# ~/.config/hypr/hyprland.conf   (hyprlang syntax, <=0.54 / still accepted)
windowrulev2 = float, class:^(emacs)$, title:^(OpenCode Prompt)$
windowrulev2 = size 80 24, class:^(emacs)$, title:^(OpenCode Prompt)$
windowrulev2 = center, class:^(emacs)$, title:^(OpenCode Prompt)$
windowrulev2 = pin,    class:^(emacs)$, title:^(OpenCode Prompt)$   # optional: show on all workspaces
```

`windowrulev2`'s syntax is `windowrulev2 = <RULE>, <matcher>[, <matcher>...]`
where each matcher is `field:regex` (e.g. `class:^(emacs)$`,
`title:^(OpenCode Prompt)$`) and **all matchers must match** (AND). `class` is
the WM_CLASS (Emacs sets it to `emacs`) and `title` is the window title --
which Emacs sets from the frame `name` parameter (section 2a). Because you
create the frame with `(name . "OpenCode Prompt")` (or call `set-frame-name`),
the `title:` matcher matches exactly that frame and **not** the user's main
Emacs window. The wiki confirms `class` and `title` are `[RegEx]` "props"
matched against the window's `class`/`title` (Window-Rules.md, "Props" table).

For the **new Lua config** (Hyprland >=0.55), the equivalent is:

```lua
-- ~/.config/hypr/hyprland.lua
hl.window_rule({
  match = { class = "emacs", title = "OpenCode Prompt" },
  float = true,
  size = { 80, 24 },   -- note: character-grid sizing is Emacs's job; Hyprland sizes in pixels
  center = true,
})
```

(Window-Rules.md, "Syntax" + "Props"/"Effects" tables: `match.class`,
`match.title`, effect `float`, `size`, `center`.)

### 8b. Setting the frame title from Elisp

Confirmed: `set-frame-name` (frame.el:2128) calls
`modify-frame-parameters (selected-frame) (list (cons 'name name))`. So either
set `(name . "OpenCode Prompt")` in the `make-frame` alist, or after creation:

```elisp
(let ((fr (make-frame '((minibuffer . t) (width . 80) (height . 24)
                        (unsplittable . t) (auto-raise . t) (visibility . t)
                        (name . "OpenCode Prompt")))))
  ;; (set-frame-name "OpenCode Prompt")  ; equivalent, if you need to rename later
  fr)
```

Hyprland reads the title from the Wayland `xdg_toplevel.title`, which pgtk
Emacs keeps in sync with the frame `name` parameter.

### 8c. Can Hyprland rules be set programmatically at runtime?

**No** -- window rules live in `~/.config/hypr/hyprland.conf` (or `.lua`) and
are loaded at startup/reload. Emacs cannot inject a rule at runtime; the user
must add the rule for your frame's title. (You *can* `hyprctl reload` after
writing to the config, but editing a user's compositor config from a package
is intrusive and brittle -- prefer a documented snippet the user pastes.)

### 8d. Floating a window at runtime via `hyprctl dispatch`

You can instead float the new frame **imperatively** after `make-frame`, by
shelling out to `hyprctl`. The Dispatchers doc (Dispatchers.md, "Window"
parameter type) confirms a window can be selected by:
- regexes: `class:...`, `title:...`,
- exact selectors: `pid:...`, `address:0x...`,
- or `activewindow` / `floating` / `tiled`.

The float dispatcher (Dispatchers.md, "Window" table) is
`float({ action?, window? })` in Lua, or the legacy CLI `hyprctl dispatch
setfloating` / `togglefloating` (confirmed in the 0.54 wiki:
*"setfloating sets the current window's floating state to true; left empty /
active for current, or window for a specific window"*). So two options:

**Option A -- float the active window right after `make-frame`** (simplest; the
new frame is focused on creation because of `auto-raise`):

```elisp
(defun opencode--hyprland-float-active ()
  "Float the currently focused window (the just-created frame)."
  (when (executable-find "hyprctl")
    (call-process "hyprctl" nil 0 nil "dispatch" "setfloating")))
```

**Option B -- float by title** (robust against focus races):

```elisp
(defun opencode--hyprland-float-by-title (title)
  "Float the Hyprland window whose title matches TITLE."
  (when (executable-find "hyprctl")
    (call-process "hyprctl" nil 0 nil "dispatch" "setfloating"
                  (concat "title:" title))))
```

**Option C -- by address**, which avoids regex/title spaces entirely. Get the
address from `hyprctl clients -j` (JSON) matching the title, then
`hyprctl dispatch setfloating address:0x...`. The "Window" parameter doc lists
`address:0x...` as an exact selector. This is the most reliable but most code.

A hybrid that works well in practice: create the frame, then immediately
`hyprctl dispatch setfloating` on the active window (Option A). If you also
want explicit size/centering, follow with `hyprctl dispatch moveactive` /
`resizeactive`, or just set `(width . 80) (height . 24)` on the Emacs frame and
let `center` come from a static rule. Whichever you pick, **guard with
`(executable-find "hyprctl")`** and `(eq window-system 'pgtk)` / `(featurep
'pgtk)` so the package degrades gracefully on X11/terminal Emacs.

**Cite:** Hyprland wiki -- `content/Configuring/Basics/Window-Rules.md`
(`match.class`/`match.title`, effect `float`/`size`/`center`) and
`content/Configuring/Basics/Dispatchers.md` ("Window" parameter type with
`class:...`, `title:...`, `address:0x...`; `float`/`setfloating` dispatcher),
from https://github.com/hyprwm/hyprland-wiki . Legacy `windowrulev2`/`setfloating`
text confirmed against the versioned 0.54 site
(https://wiki.hypr.land/0.54.0/Configuring/Dispatchers/).

---

## TL;DR recommendations for the package

1. **Popup:** `make-frame` with `(name . "OpenCode Prompt")`,
   `(unsplittable . t)`, `(minibuffer . t)`, sized 80x24. On Hyprland add a
   `windowrulev2 = float, class:^(emacs)$, title:^(OpenCode Prompt)$` (or
   `hyprctl dispatch setfloating` right after `make-frame`). Avoid posframe --
   it's for read-only tooltips, not an evil editor.
2. **`:w` to send:** `(setq-local evil-ex-commands (copy-alist
   evil-ex-commands))` then `(evil-ex-define-cmd "w[rite]" #'opencode-prompt-send)`
   in the prompt buffer. `delete-frame` on send.
3. **Backend transport:** start `opencode serve --port 0`, parse the port from
   its stdout (process filter). Use `plz`/`url-retrieve` for ordinary HTTP API
   calls; use a **`make-process` + `curl -N`** subprocess with a custom filter
   for the SSE `/.../event` stream (remember `utf-8-unix` coding and
   `process-adaptive-read-buffering nil`). Model it on
   `karta0807913/opencode-sse.el`.
4. **Chat buffer streaming:** copy gptel's tracking-marker pattern
   (`gptel-curl--stream-insert-response`, gptel.el:1841) and comint's
   `inhibit-read-only` + process-mark insertion (comint.el:2202). Set
   `window-point-insertion-type` to `t`. Render with `markdown-mode` (or gptel's
   markdown->org converter for org buffers). Coalesce bursts with
   `run-with-idle-timer`.
5. **Sessions picker:** `completing-read` for portability; optionally
   `consult--read` with `:annotate` + a `:state` preview function for a richer
   "step into a previous session" UX.
