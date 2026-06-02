#!/usr/bin/env bash
# Terminal driver: iTerm2 (macOS only)
# Uses AppleScript to control iTerm2 sessions.
set -euo pipefail

_iterm2_run() {
  osascript -e "$1" 2>/dev/null
}

driver_spawn() {
  local command="$1" cwd="$2" _main_pane="$3" session_root="$4"
  local session_id tty_path

  session_id="$(basename "$session_root")"

  tty_path="$(_iterm2_run "
    tell application \"iTerm2\"
      tell current window
        tell current session
          set newSession to (split horizontally with default profile)
          tell newSession
            write text \"cd $(printf '%q' "$cwd") && $command\"
            set name to \"codex-review:$session_id\"
            return tty
          end tell
        end tell
      end tell
    end tell
  ")"

  printf '%s\n' "$tty_path" > "$session_root/.codex-pane-id"
  printf '%s\n' "$tty_path" > "$session_root/.codex-terminal-id"

  driver_wait_prompt "$tty_path" "›" 60000

  printf '%s' "$tty_path"
}

driver_send() {
  local pane_id="$1" text="$2"
  _iterm2_run "
    tell application \"iTerm2\"
      tell current window
        repeat with aTab in tabs
          repeat with aSession in sessions of aTab
            if tty of aSession is \"$pane_id\" then
              tell aSession to write text \"$text\"
              return
            end if
          end repeat
        end repeat
      end tell
    end tell
  "
}

driver_wait_prompt() {
  local pane_id="$1" match="$2" timeout_ms="${3:-60000}"
  local elapsed=0 interval=2

  while [ "$elapsed" -lt "$((timeout_ms / 1000))" ]; do
    local contents
    contents="$(_iterm2_run "
      tell application \"iTerm2\"
        tell current window
          repeat with aTab in tabs
            repeat with aSession in sessions of aTab
              if tty of aSession is \"$pane_id\" then
                return contents of aSession
              end if
            end repeat
          end repeat
        end tell
      end tell
    ")" || true
    if printf '%s' "$contents" | grep -qF "$match"; then
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  echo "ABORT: prompt '$match' not detected within ${timeout_ms}ms in iTerm2 session $pane_id" >&2
  return 1
}

driver_close() {
  local pane_id="$1"
  _iterm2_run "
    tell application \"iTerm2\"
      tell current window
        repeat with aTab in tabs
          repeat with aSession in sessions of aTab
            if tty of aSession is \"$pane_id\" then
              tell aSession to close
              return
            end if
          end repeat
        end repeat
      end tell
    end tell
  " || true
}

driver_status() {
  local pane_id="$1"
  local exists
  exists="$(_iterm2_run "
    tell application \"iTerm2\"
      tell current window
        repeat with aTab in tabs
          repeat with aSession in sessions of aTab
            if tty of aSession is \"$pane_id\" then return \"alive\"
          end repeat
        end repeat
      end tell
      return \"gone\"
    end tell
  ")" || printf 'gone'
  printf '%s' "${exists:-gone}"
}

driver_info() {
  local pane_id="$1"
  printf '{"pane_id":"%s","driver":"iterm2"}' "$pane_id"
}

driver_rename() {
  local pane_id="$1" label="$2"
  _iterm2_run "
    tell application \"iTerm2\"
      tell current window
        repeat with aTab in tabs
          repeat with aSession in sessions of aTab
            if tty of aSession is \"$pane_id\" then
              set name of aSession to \"$label\"
              return
            end if
          end repeat
        end repeat
      end tell
    end tell
  " || true
}

driver_list_workspace() {
  local _workspace_id="$1"
  _iterm2_run "
    tell application \"iTerm2\"
      tell current window
        set output to \"\"
        repeat with aTab in tabs
          repeat with aSession in sessions of aTab
            set output to output & (tty of aSession) & \" \" & (name of aSession) & \"\n\"
          end repeat
        end repeat
        return output
      end tell
    end tell
  " || printf ''
}
