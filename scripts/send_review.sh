#!/usr/bin/env bash
# Render and send a review prompt to the Codex pane for round N.
#   round 1 → prompts/base-review-v1.md + role + framing
#   round N≥2 → prompts/base-review-vn.md + role + framing
#
# Usage: send_review.sh <session_root> <round> [role]
#
# role defaults to "plan-correctness". When a role is specified, the output
# file is named vN.<role>.review-comments.yaml instead of vN.review-comments.yaml.
#
# The script asserts pane ownership, renders the template (no sed; render_template.py
# handles arbitrary characters), and sends text + Enter. It does NOT wait for done —
# the caller decides how long to wait.
set -euo pipefail

fail() { printf 'ABORT: %s\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/_skill_dir.sh"

SESSION_ROOT="${1:-}"
ROUND="${2:-}"
ROLE="${3:-plan-correctness}"
[ -n "$SESSION_ROOT" ] || fail "missing arg 1: session_root"
[ -n "$ROUND" ]        || fail "missing arg 2: round"
case "$ROUND" in ''|*[!0-9]*) fail "round must be a positive integer, got: $ROUND" ;; esac
[ "$ROUND" -ge 1 ]     || fail "round must be >= 1, got: $ROUND"

REVIEW_MODE="${REVIEW_MODE:-codex}"

if [ "$REVIEW_MODE" != "subagent" ]; then
  "$SCRIPT_DIR/assert_pane_owned.sh" "$SESSION_ROOT"
fi

CODEX_PANE="$(cat "$SESSION_ROOT/.codex-pane-id" 2>/dev/null || echo 'none')"
PLAN_PATH="$SESSION_ROOT/v${ROUND}.md"

# Output path includes role when multiple roles are in use
REVIEW_ROLES="${REVIEW_ROLES:-plan-correctness}"
if printf '%s' "$REVIEW_ROLES" | grep -q ','; then
  OUTPUT_PATH="$SESSION_ROOT/v${ROUND}.${ROLE}.review-comments.yaml"
else
  OUTPUT_PATH="$SESSION_ROOT/v${ROUND}.review-comments.yaml"
fi

[ -f "$PLAN_PATH" ] || fail "missing plan file: $PLAN_PATH"
[ -s "$SESSION_ROOT/spec-context.md" ] || fail "spec-context.md missing or empty — prereview_boot must produce non-empty output"

# Select framing based on review mode
case "$REVIEW_MODE" in
  subagent) FRAMING_FILE="$SKILL_DIR/prompts/framing/adversarial.md" ;;
  *)        FRAMING_FILE="$SKILL_DIR/prompts/framing/neutral.md" ;;
esac

# Select role instructions
ROLE_FILE="$SKILL_DIR/prompts/roles/${ROLE}.md"
[ -f "$ROLE_FILE" ] || fail "unknown role: $ROLE (no file at $ROLE_FILE)"

if [ "$ROUND" -eq 1 ]; then
  TEMPLATE="$SKILL_DIR/prompts/base-review-v1.md"
  PROMPT="$("$SCRIPT_DIR/render_template.py" "$TEMPLATE" \
    "PLAN_PATH=$PLAN_PATH" \
    "OUTPUT_PATH=$OUTPUT_PATH" \
    "SPEC_CONTEXT_FILE=$SESSION_ROOT/spec-context.md" \
    "FRAMING_FILE=$FRAMING_FILE" \
    "ROLE_INSTRUCTIONS_FILE=$ROLE_FILE")"
else
  TEMPLATE="$SKILL_DIR/prompts/base-review-vn.md"
  PREV="$((ROUND - 1))"
  PREV_DISPO="$SESSION_ROOT/v${PREV}.dispositions.yaml"
  DIFF_PATH="$SESSION_ROOT/v${ROUND}.diff"
  [ -f "$PREV_DISPO" ] || fail "missing prev dispositions: $PREV_DISPO"
  [ -f "$DIFF_PATH"  ] || fail "missing diff: $DIFF_PATH"
  PROMPT="$("$SCRIPT_DIR/render_template.py" "$TEMPLATE" \
    "PLAN_PATH=$PLAN_PATH" \
    "PREV_DISPOSITION=$PREV_DISPO" \
    "DIFF_PATH=$DIFF_PATH" \
    "OUTPUT_PATH=$OUTPUT_PATH" \
    "SPEC_CONTEXT_FILE=$SESSION_ROOT/spec-context.md" \
    "FRAMING_FILE=$FRAMING_FILE" \
    "ROLE_INSTRUCTIONS_FILE=$ROLE_FILE")"
fi

if [ "$REVIEW_MODE" != "subagent" ]; then
  # Load the appropriate driver
  TERMINAL_DRIVER="${TERMINAL_DRIVER:-$("$SCRIPT_DIR/detect_driver.sh")}"
  . "$SCRIPT_DIR/drivers/${TERMINAL_DRIVER}.sh"
  driver_send "$CODEX_PANE" "$PROMPT"
else
  # Subagent mode: write prompt to a file for the caller to use
  printf '%s' "$PROMPT" > "$SESSION_ROOT/v${ROUND}.${ROLE}.prompt"
fi

printf 'sent round=%s output=%s\n' "$ROUND" "$OUTPUT_PATH"
