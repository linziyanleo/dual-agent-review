#!/usr/bin/env bash
# Detect the best available terminal driver.
# Prints the driver name to stdout. Exits 1 if none found.
# Can be overridden by setting TERMINAL_DRIVER env var.
set -euo pipefail

if [ -n "${TERMINAL_DRIVER:-}" ]; then
  printf '%s' "$TERMINAL_DRIVER"
  exit 0
fi

if [ "${REVIEW_MODE:-codex}" = "subagent" ]; then
  printf 'subagent'
elif [ "${HERDR_ENV:-}" = "1" ]; then
  printf 'herdr'
elif [ -n "${TMUX:-}" ]; then
  printf 'tmux'
elif [ "$(uname)" = "Darwin" ] && osascript -e 'tell application "iTerm2" to get version' >/dev/null 2>&1; then
  printf 'iterm2'
else
  echo "ERROR: no supported terminal driver found. Set TERMINAL_DRIVER or use REVIEW_MODE=subagent." >&2
  exit 1
fi
