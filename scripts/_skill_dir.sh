#!/usr/bin/env bash
# Source-only helper: exports $SKILL_DIR pointing at the dual-agent-review skill root.
# Resolves through symlinks so $SKILL_DIR works whether the skill is invoked through
# ~/.claude/skills/... (a symlink) or its real source repo.
#
# Usage from another script:
#   . "$(dirname "${BASH_SOURCE[0]}")/_skill_dir.sh"
# After sourcing, "$SKILL_DIR/scripts/xxx.sh" etc. are addressable.

# realpath is preferred; fall back to a portable substitute on systems where it is missing.
__dar_resolve() {
  if command -v realpath >/dev/null 2>&1; then
    realpath "$1"
  else
    python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"
  fi
}

SKILL_DIR="$(cd "$(dirname "$(__dar_resolve "${BASH_SOURCE[0]}")")/.." && pwd)"
export SKILL_DIR
unset -f __dar_resolve
