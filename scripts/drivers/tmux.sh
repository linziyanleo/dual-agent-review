#!/usr/bin/env bash
# Terminal driver: tmux
# Uses tmux commands behind the standard driver interface.
set -euo pipefail

driver_spawn() {
  local command="$1" cwd="$2" main_pane="$3" session_root="$4"
  local new_pane

  new_pane="$(tmux split-window -h -t "$main_pane" -c "$cwd" -P -F '#{pane_id}')"

  printf '%s\n' "$new_pane" > "$session_root/.codex-pane-id"
  printf '%s\n' "$new_pane" > "$session_root/.codex-terminal-id"

  local session_id
  session_id="$(basename "$session_root")"
  tmux select-pane -t "$new_pane" -T "codex-review:${session_id}" 2>/dev/null || true

  tmux send-keys -t "$new_pane" "$command" Enter

  driver_wait_prompt "$new_pane" "›" 60000

  printf '%s' "$new_pane"
}

driver_send() {
  local pane_id="$1" text="$2"
  tmux send-keys -t "$pane_id" "$text" Enter
}

driver_wait_prompt() {
  local pane_id="$1" match="$2" timeout_ms="${3:-60000}"
  local deadline elapsed=0 interval=2

  while [ "$elapsed" -lt "$((timeout_ms / 1000))" ]; do
    if tmux capture-pane -t "$pane_id" -p 2>/dev/null | grep -qF "$match"; then
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  echo "ABORT: prompt '$match' not detected within ${timeout_ms}ms in tmux pane $pane_id" >&2
  return 1
}

driver_close() {
  local pane_id="$1"
  tmux kill-pane -t "$pane_id" 2>/dev/null || true
}

driver_status() {
  local pane_id="$1"
  if tmux has-session -t "$pane_id" 2>/dev/null; then
    printf 'alive'
  else
    printf 'gone'
  fi
}

driver_info() {
  local pane_id="$1"
  local pid tty title
  pid="$(tmux display-message -t "$pane_id" -p '#{pane_pid}' 2>/dev/null || echo '')"
  tty="$(tmux display-message -t "$pane_id" -p '#{pane_tty}' 2>/dev/null || echo '')"
  title="$(tmux display-message -t "$pane_id" -p '#{pane_title}' 2>/dev/null || echo '')"
  printf '{"pane_id":"%s","pid":"%s","tty":"%s","title":"%s"}' "$pane_id" "$pid" "$tty" "$title"
}

driver_rename() {
  local pane_id="$1" label="$2"
  tmux select-pane -t "$pane_id" -T "$label" 2>/dev/null || true
}

driver_list_workspace() {
  local _workspace_id="$1"
  tmux list-panes -F '#{pane_id} #{pane_title}' 2>/dev/null || printf ''
}
