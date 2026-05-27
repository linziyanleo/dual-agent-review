#!/usr/bin/env bash
# Boot spec-anchor and write spec-context.md for injection into review prompts.
# Sources SA_SKILL_DIR from session.env, invokes specanchor-boot.sh --format=summary.
#
# Usage: prereview_boot.sh <session_root>
# Exit 0 on success (non-empty spec-context.md).
# Exit 1 if boot script fails OR produces empty output.
set -euo pipefail

fail() { printf 'ABORT: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

SESSION_ROOT="${1:-}"
[ -n "$SESSION_ROOT" ] || fail "missing arg 1: session_root"
[ -f "$SESSION_ROOT/session.env" ] || fail "session.env not found in $SESSION_ROOT"

set -a
. "$SESSION_ROOT/session.env"
set +a

[ -n "${SA_SKILL_DIR:-}" ] || fail "SA_SKILL_DIR not found in session.env"

BOOT_SCRIPT="$SA_SKILL_DIR/scripts/specanchor-boot.sh"
[ -f "$BOOT_SCRIPT" ] || fail "specanchor-boot.sh not found: $BOOT_SCRIPT"

SPEC_CONTEXT="$SESSION_ROOT/spec-context.md"

SPECANCHOR_SKILL_DIR="$SA_SKILL_DIR" bash "$BOOT_SCRIPT" --format=summary > "$SPEC_CONTEXT"

if [ ! -s "$SPEC_CONTEXT" ]; then
  fail "specanchor-boot produced empty output — cannot review without Spec context"
fi

printf 'prereview_boot OK: %s\n' "$SPEC_CONTEXT"
