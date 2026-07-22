#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)

command -v emacs >/dev/null || {
    echo "missing required command: emacs" >&2
    exit 1
}
if [[ -z ${OC_HP_SKIP_INTEGRATION:-} ]]; then
    command -v opencode >/dev/null || {
        echo "missing required command: opencode" >&2
        exit 1
    }
fi
command -v curl >/dev/null || {
    echo "missing required command: curl" >&2
    exit 1
}

emacs --batch -Q -L "$root" \
    --eval '(setq load-prefer-newer t)' \
    -l "$root/tests/opencode-hyprland-popup-tests.el" \
    -f oc-hp-run-batch-tests

emacs --batch -Q -L "$root" \
    --eval '(setq load-prefer-newer t)' \
    -l "$root/tests/opencode-hyprland-popup-ert.el" \
    -f ert-run-tests-batch-and-exit
