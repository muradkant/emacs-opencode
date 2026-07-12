#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)

command -v emacs >/dev/null || {
    echo "missing required command: emacs" >&2
    exit 1
}
command -v opencode >/dev/null || {
    echo "missing required command: opencode" >&2
    exit 1
}
command -v curl >/dev/null || {
    echo "missing required command: curl" >&2
    exit 1
}

exec emacs --batch -Q -L "$root" \
    -l "$root/tests/opencode-hyprland-popup-tests.el" \
    -f oc-hp-run-batch-tests
