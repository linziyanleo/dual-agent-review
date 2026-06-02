#!/usr/bin/env python3
"""Merge per-role review-comments into a single canonical file.

Usage: merge_review_comments.py <session_root> <round_number>

Scans for vN.<role>.review-comments.yaml files, merges them into
vN.review-comments.yaml with role-prefixed finding_ids.

Role prefix mapping:
  plan-correctness  -> PC-
  spec-completeness -> SC-
"""
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("ABORT: PyYAML not importable", file=sys.stderr)
    sys.exit(1)

ROLE_PREFIXES = {
    "plan-correctness": "PC",
    "spec-completeness": "SC",
}

VERDICT_ORDER = {"block": 2, "request_changes": 1, "approve": 0}


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: merge_review_comments.py <session_root> <round>", file=sys.stderr)
        return 2

    session_root = Path(sys.argv[1])
    round_num = sys.argv[2]
    prefix = f"v{round_num}"

    role_files = sorted(session_root.glob(f"{prefix}.*.review-comments.yaml"))
    if not role_files:
        canon = session_root / f"{prefix}.review-comments.yaml"
        if canon.is_file():
            return 0
        print(f"ABORT: no role-specific review-comments found for {prefix} in {session_root}", file=sys.stderr)
        return 1

    merged_verdict = "approve"
    summaries = []
    merged_findings = []

    for rf in role_files:
        stem_parts = rf.stem.split(".")
        role = ".".join(stem_parts[1:-1])
        role_prefix = ROLE_PREFIXES.get(role, role.upper()[:2])

        raw = rf.read_text(encoding="utf-8")
        doc = yaml.safe_load(raw)
        if not isinstance(doc, dict):
            print(f"ABORT: {rf} top-level is not a mapping", file=sys.stderr)
            return 1

        verdict = doc.get("overall_verdict", "approve")
        if VERDICT_ORDER.get(verdict, 0) > VERDICT_ORDER.get(merged_verdict, 0):
            merged_verdict = verdict

        summary = doc.get("summary", "")
        if summary:
            summaries.append(f"[{role}] {summary}")

        for finding in doc.get("review_comments", []):
            fid = finding.get("finding_id", "F-?")
            finding["finding_id"] = f"{role_prefix}-{fid}"
            merged_findings.append(finding)

    if merged_verdict == "approve" and merged_findings:
        merged_verdict = "request_changes"

    merged = {
        "overall_verdict": merged_verdict,
        "summary": " ".join(summaries),
        "review_comments": merged_findings,
    }

    canon_path = session_root / f"{prefix}.review-comments.yaml"
    canon_path.write_text(
        yaml.dump(merged, default_flow_style=False, allow_unicode=True, sort_keys=False),
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
