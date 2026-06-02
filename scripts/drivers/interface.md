# Terminal Driver Interface

Each driver exports these functions. Source the driver file to use them.

## Driver-layer primitives

```bash
driver_spawn COMMAND CWD MAIN_PANE SESSION_ROOT
# Creates a new terminal pane, runs COMMAND, waits for prompt readiness.
# Writes CODEX_PANE and CODEX_TERMINAL to $SESSION_ROOT/session.env.
# Prints pane_id to stdout.

driver_send PANE_ID TEXT
# Sends TEXT to the pane, followed by Enter.

driver_wait_prompt PANE_ID MATCH TIMEOUT_MS
# Waits for MATCH to appear in pane output. Used only for spawn-stage
# prompt readiness detection. NOT for review completion.

driver_close PANE_ID [--force]
# Closes the pane. Without --force, only closes if status is done/idle/gone.

driver_status PANE_ID
# Prints one of: working, blocked, done, idle, gone, unknown
# This is a HINT only — never the success signal for review completion.

driver_info PANE_ID
# Prints JSON with driver-specific metadata (workspace_id, terminal_id, etc.)

driver_rename PANE_ID LABEL
# Renames/labels the pane for human identification.

driver_list_workspace WORKSPACE_ID
# Lists panes in the workspace. Prints JSON array.
```

## Application-layer (shared, not per-driver)

Review completion is handled by `wait_codex_done.sh`:
- Success signal: OUTPUT_PATH file exists and is non-empty
- driver_status is used only to shorten failure reporting (early exit on crash)
- driver_wait_prompt is used only during spawn to detect Codex readiness

This two-layer design ensures no driver can claim review success without a file.
