#!/usr/bin/env python3
"""Decide whether the review loop has converged after round N.

Usage: check_convergence.py <session_root> <round>

Exit codes:
  0 — decision printed on stdout (one of the verdict enums below).
  1 — IO / YAML / argument / domain-data error (stderr explains).

Stdout (single line, one of):
  CONVERGED_APPROVE       Codex's overall_verdict for round N is "approve".
  CONVERGED_NO_BLOCKERS   round N and round N-1 both have zero high/medium findings.
  MAX_ROUNDS_REACHED      round >= 5 with no other convergence condition.
  CONTINUE                none of the above; proceed to round N+1.

Workflow gate: if v(N).findings.yaml has any findings AND v(N).dispositions.yaml
does not yet exist, return CONTINUE. The convergence verdicts above require an
explicit disposition for every finding in the current round, so the workflow
must write v(N).dispositions before this script can finalize.

Returning exit 0 for every valid decision is intentional: callers that run with
`set -euo pipefail` can use `case "$(...)" in ... esac` without disabling errexit.
"""
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("ABORT: PyYAML not importable", file=sys.stderr)
    sys.exit(1)


MAX_ROUNDS = 5
BLOCKER_SEVERITIES = {"high", "medium"}


def load_findings(path: Path) -> dict:
    if not path.is_file():
        raise FileNotFoundError(f"findings file not found: {path}")
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except yaml.YAMLError as e:
        raise ValueError(f"YAML parse error in {path}: {e}") from e
    if not isinstance(data, dict):
        raise ValueError(f"top-level of {path} must be a mapping")
    return data


def no_blocker(findings_doc: dict) -> bool:
    if findings_doc.get("overall_verdict") == "block":
        return False
    findings = findings_doc.get("findings", [])
    if not isinstance(findings, list):
        raise ValueError("findings must be a list")
    for f in findings:
        if not isinstance(f, dict):
            raise ValueError("each finding must be a mapping")
        sev = f.get("severity")
        if sev in BLOCKER_SEVERITIES:
            return False
    return True


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: check_convergence.py <session_root> <round>", file=sys.stderr)
        return 1
    session_root = Path(sys.argv[1])
    try:
        n = int(sys.argv[2])
    except ValueError:
        print(f"ABORT: round must be int, got {sys.argv[2]!r}", file=sys.stderr)
        return 1
    if n < 1:
        print(f"ABORT: round must be >= 1, got {n}", file=sys.stderr)
        return 1

    try:
        current = load_findings(session_root / f"v{n}.findings.yaml")
    except (FileNotFoundError, ValueError) as e:
        print(f"ABORT: {e}", file=sys.stderr)
        return 1

    verdict = current.get("overall_verdict")
    if verdict not in {"approve", "request_changes", "block"}:
        print(f"ABORT: invalid overall_verdict={verdict!r} in v{n}.findings.yaml", file=sys.stderr)
        return 1

    # Workflow gate: every finding in the current round must have a disposition before
    # the loop can finalize. If findings is non-empty and v(N).dispositions.yaml has not
    # been written yet, return CONTINUE so the caller goes back and records dispositions.
    current_findings = current.get("findings") or []
    if current_findings and not (session_root / f"v{n}.dispositions.yaml").is_file():
        print("CONTINUE")
        return 0

    # Condition A: approve with no contradictory findings.
    if verdict == "approve" and no_blocker(current):
        print("CONVERGED_APPROVE")
        return 0

    # Condition B (needs round N >= 2): both rounds clean.
    if n >= 2:
        try:
            prev = load_findings(session_root / f"v{n - 1}.findings.yaml")
        except (FileNotFoundError, ValueError) as e:
            print(f"ABORT: {e}", file=sys.stderr)
            return 1
        if no_blocker(current) and no_blocker(prev):
            print("CONVERGED_NO_BLOCKERS")
            return 0

    # Condition C
    if n >= MAX_ROUNDS:
        print("MAX_ROUNDS_REACHED")
        return 0

    print("CONTINUE")
    return 0


if __name__ == "__main__":
    sys.exit(main())
