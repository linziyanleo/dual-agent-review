#!/usr/bin/env bash
# Terminal driver: herdr
# Wraps herdr CLI commands behind the standard driver interface.
set -euo pipefail

driver_spawn() {
  local command="$1" cwd="$2" main_pane="$3" session_root="$4"
  local split_json new_pane terminal_id

  split_json="$(herdr pane split "$main_pane" --direction right --no-focus --cwd "$cwd")"
  new_pane="$(printf '%s' "$split_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['pane']['pane_id'])")"
  terminal_id="$(printf '%s' "$split_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['pane']['terminal_id'])")"

  printf '%s\n' "$new_pane"  > "$session_root/.codex-pane-id"
  printf '%s\n' "$terminal_id" > "$session_root/.codex-terminal-id"

  local session_id
  session_id="$(basename "$session_root")"
  herdr pane rename "$new_pane" "codex-review:${session_id}" >/dev/null
  herdr pane run    "$new_pane" "$command" >/dev/null

  herdr wait output "$new_pane" --match "›" --timeout 60000 >/dev/null \
    || { echo "ABORT: codex prompt '›' not detected within 60s" >&2; exit 1; }

  printf '%s' "$new_pane"
}

driver_send() {
  local pane_id="$1" text="$2"
  herdr pane send-text "$pane_id" "$text"
  herdr pane send-keys "$pane_id" Enter
}

driver_wait_prompt() {
  local pane_id="$1" match="$2" timeout_ms="${3:-60000}"
  herdr wait output "$pane_id" --match "$match" --timeout "$timeout_ms" >/dev/null
}

driver_close() {
  local pane_id="$1"
  herdr pane close "$pane_id" >/dev/null 2>&1 || true
}

driver_status() {
  local pane_id="$1"
  local info
  info="$(herdr pane get "$pane_id" 2>/dev/null)" || { printf 'gone'; return; }
  printf '%s' "$info" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('result',{}).get('pane',{}).get('agent_status','unknown'))
except: print('unknown')
"
}

driver_info() {
  local pane_id="$1"
  herdr pane get "$pane_id" 2>/dev/null || printf '{}'
}

driver_rename() {
  local pane_id="$1" label="$2"
  herdr pane rename "$pane_id" "$label" >/dev/null 2>&1 || true
}

driver_list_workspace() {
  local workspace_id="$1"
  herdr pane list --workspace "$workspace_id" 2>/dev/null || printf '[]'
}
