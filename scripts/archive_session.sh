#!/usr/bin/env bash
# Move a converged review session from .specanchor/tasks/ to .specanchor/archive/.
#
# Usage: archive_session.sh <session_root>
# Exit 0 on success (prints new path to stdout).
# Exit 1 if session has no final.md (not converged) or move fails.
set -euo pipefail

fail() { printf 'ABORT: %s\n' "$*" >&2; exit 1; }

SESSION_ROOT="${1:-}"
[ -n "$SESSION_ROOT" ] || fail "missing arg 1: session_root"
[ -d "$SESSION_ROOT" ] || fail "session_root does not exist: $SESSION_ROOT"
[ -e "$SESSION_ROOT/final.md" ] || fail "session has no final.md — archive only after convergence"

SESSION_NAME="$(basename "$SESSION_ROOT")"
ARCHIVE_DIR="$(cd "$SESSION_ROOT/../.." && pwd)/archive"

mkdir -p "$ARCHIVE_DIR"
DEST="$ARCHIVE_DIR/$SESSION_NAME"

[ ! -e "$DEST" ] || fail "archive destination already exists: $DEST"

mv "$SESSION_ROOT" "$DEST"
printf '%s\n' "$DEST"
