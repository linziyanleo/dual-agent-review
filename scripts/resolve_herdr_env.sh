#!/usr/bin/env bash
# Resolve HERDR_ENV + HERDR_PANE_ID for the current Claude session.
#
# Fast path: if both env vars are already set, echo them and exit.
# Fallback:  use `herdr agent list` + cwd match to auto-detect the pane.
#
# stdout: POSIX shell lines (HERDR_ENV='1'  HERDR_PANE_ID='<id>'), safe to eval.
# exit 0 on success, exit 1 on failure (stderr has the diagnostic).
set -euo pipefail

fail() { printf 'ABORT: %s\n' "$*" >&2; exit 1; }

if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
  printf "HERDR_ENV='1'\nHERDR_PANE_ID='%s'\n" "$HERDR_PANE_ID"
  exit 0
fi

command -v herdr >/dev/null 2>&1 || fail "herdr CLI not on PATH; cannot auto-detect pane"
command -v python3 >/dev/null 2>&1 || fail "python3 not on PATH; cannot parse herdr output"

CWD="$(pwd)"

DETECTED="$(herdr agent list 2>/dev/null | python3 -c '
import sys, json
data = json.load(sys.stdin)
agents = data.get("result", {}).get("agents", [])
cwd = sys.argv[1]
matches = [a for a in agents if a.get("agent") == "claude" and a.get("cwd") == cwd and a.get("agent_status") == "working"]
if len(matches) == 1:
    print(matches[0]["pane_id"])
elif len(matches) > 1:
    print("AMBIGUOUS", file=sys.stderr)
    for m in matches:
        pid = m["pane_id"]
        tid = m.get("terminal_id", "?")
        print(f"  pane={pid} terminal={tid}", file=sys.stderr)
    sys.exit(1)
else:
    print("NO_MATCH", file=sys.stderr)
    sys.exit(1)
' "$CWD" 2>&1)" || true

case "$DETECTED" in
  "")
    fail "herdr agent list returned no output; is herdr server running?"
    ;;
  *AMBIGUOUS*)
    fail "multiple Claude agents found for cwd=$CWD; cannot auto-detect. Set HERDR_PANE_ID explicitly."
    ;;
  *NO_MATCH*)
    fail "no working Claude agent found for cwd=$CWD via herdr agent list. Ensure herdr integration is installed (herdr integration install claude)."
    ;;
esac

printf "HERDR_ENV='1'\nHERDR_PANE_ID='%s'\n" "$DETECTED"
