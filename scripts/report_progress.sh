#!/usr/bin/env bash
# Report DAR progress to herdr sidebar via pane report-metadata.
# Usage: report_progress.sh <title> [custom-status]
#        report_progress.sh --clear
# Silently no-op if HERDR_ENV != 1 or herdr not available.
set -euo pipefail

[ "${HERDR_ENV:-}" = "1" ] || exit 0
[ -n "${HERDR_PANE_ID:-}" ] || exit 0
command -v herdr >/dev/null 2>&1 || exit 0

if [ "${1:-}" = "--clear" ]; then
  herdr pane report-metadata "$HERDR_PANE_ID" \
    --source "dar" --clear-title --clear-custom-status >/dev/null 2>&1 || true
  exit 0
fi

TITLE="${1:-}"
[ -n "$TITLE" ] || exit 0

ARGS=(herdr pane report-metadata "$HERDR_PANE_ID" --source "dar" --title "$TITLE")
[ -n "${2:-}" ] && ARGS+=(--custom-status "$2")

"${ARGS[@]}" >/dev/null 2>&1 || true
