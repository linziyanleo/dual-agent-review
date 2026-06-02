#!/usr/bin/env bash
# Terminal driver: subagent (no-op)
# Subagent mode uses Claude's Agent tool directly, not terminal panes.
# This driver provides stub implementations so init_session.sh and
# preflight.sh don't fail when TERMINAL_DRIVER=subagent.
set -euo pipefail

driver_spawn()        { printf 'subagent-virtual-pane'; }
driver_send()         { :; }
driver_wait_prompt()  { :; }
driver_close()        { :; }
driver_status()       { printf 'done'; }
driver_info()         { printf '{"driver":"subagent"}'; }
driver_rename()       { :; }
driver_list_workspace() { printf '[]'; }
