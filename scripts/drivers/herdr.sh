#!/usr/bin/env bash
# Terminal driver: herdr
# Wraps herdr CLI commands behind the standard driver interface.
# driver_spawn outputs "pane_id\nterminal_id" on stdout; caller writes session files.
set -euo pipefail

driver_spawn() {
  local command="$1" cwd="$2" main_pane="$3" session_root="$4"
  local session_id new_pane terminal_id

  session_id="$(basename "$session_root")"

  if [ "${DAR_USE_AGENT_START:-}" = "1" ]; then
    local ws tab start_json actual_ws actual_tab
    ws="$(awk -F= '$1=="WORKSPACE_ID"{print $2}' "$session_root/session.meta")"
    tab="$(awk -F= '$1=="TAB_ID"{print $2}' "$session_root/session.meta")"
    start_json="$(herdr agent start "codex-review:${session_id}" \
      --workspace "$ws" --tab "$tab" --split right --no-focus --cwd "$cwd" \
      -- "$command")"
    new_pane="$(printf '%s' "$start_json" | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["agent"]["pane_id"])')"
    terminal_id="$(printf '%s' "$start_json" | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["agent"]["terminal_id"])')"

    actual_ws="$(printf '%s' "$start_json" | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["agent"]["workspace_id"])')"
    actual_tab="$(printf '%s' "$start_json" | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["agent"]["tab_id"])')"
    if [ "$actual_ws" != "$ws" ] || [ "$actual_tab" != "$tab" ]; then
      herdr pane close "$new_pane" >/dev/null 2>&1 || true
      echo "ABORT: agent start split to ws=$actual_ws tab=$actual_tab (expected $ws:$tab)" >&2
      exit 1
    fi
  else
    local split_json
    split_json="$(herdr pane split "$main_pane" --direction right --no-focus --cwd "$cwd")"
    new_pane="$(printf '%s' "$split_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['pane']['pane_id'])")"
    terminal_id="$(printf '%s' "$split_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['pane']['terminal_id'])")"

    herdr pane rename "$new_pane" "codex-review:${session_id}" >/dev/null
    herdr pane run "$new_pane" "$command" >/dev/null
  fi

  herdr wait output "$new_pane" --match "›" --timeout 60000 >/dev/null \
    || { echo "ABORT: codex prompt '›' not detected within 60s" >&2; exit 1; }

  printf '%s\n%s\n' "$new_pane" "$terminal_id"
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
