#!/usr/bin/env python3
"""Validate a Codex review-comments YAML against the dual-agent-review schema.

Usage: validate_review_comments.py [--role ROLE] <review_comments_path>

--role: Optional. When omitted (None), uses the union of all role category sets
        (for validating canonical merged files). When provided, restricts to that
        role's category subset.

Exit 0 on success (no stdout). Exit 1 with a single human-readable error line on
stdout — the line is embedded directly into the retry prompt template, so it must
stand alone and name the file + the broken field path.
"""
import argparse
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("ABORT: PyYAML not importable", file=sys.stderr)
    sys.exit(1)


VERDICTS = {"approve", "request_changes", "block"}
SEVERITIES = {"high", "medium", "low", "nit"}

ROLE_CATEGORIES = {
    "plan-correctness": {
        "correctness", "security", "performance", "maintainability",
        "scope", "testing", "unclear-requirements", "other",
    },
    "spec-completeness": {
        "spec-gap", "contract-ambiguity", "correctness",
        "scope", "unclear-requirements", "other",
    },
}

ALL_CATEGORIES = set()
for _cats in ROLE_CATEGORIES.values():
    ALL_CATEGORIES |= _cats

REQUIRED_FINDING_KEYS = (
    "finding_id", "severity", "category", "location",
    "description", "suggested_change", "rationale",
)


def fail(msg: str) -> int:
    print(msg)
    return 1


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--role", default=None, choices=list(ROLE_CATEGORIES.keys()))
    parser.add_argument("path")
    args = parser.parse_args()

    categories = ROLE_CATEGORIES[args.role] if args.role else ALL_CATEGORIES
    path = Path(args.path)
    if not path.is_file():
        return fail(f"{path}: file does not exist")

    raw = path.read_text(encoding="utf-8")
    if not raw.strip():
        return fail(f"{path}: file is empty")

    try:
        doc = yaml.safe_load(raw)
    except yaml.YAMLError as e:
        hint = ""
        err_str = str(e)
        if "mapping values are not allowed here" in err_str:
            hint = " [hint: a string value likely contains unquoted `: ` (colon-space) — wrap it in double quotes]"
        return fail(f"{path}: YAML parse error: {e}{hint}")

    if not isinstance(doc, dict):
        return fail(f"{path}: top-level must be a mapping")

    verdict = doc.get("overall_verdict")
    if verdict not in VERDICTS:
        return fail(f"{path}: overall_verdict must be one of {sorted(VERDICTS)}, got {verdict!r}")

    if not isinstance(doc.get("summary"), str) or not doc["summary"].strip():
        return fail(f"{path}: summary must be a non-empty string")

    findings = doc.get("review_comments")
    if not isinstance(findings, list):
        return fail(f"{path}: review_comments must be a list (got {type(findings).__name__})")

    seen_ids: dict[str, int] = {}
    for i, f in enumerate(findings):
        loc = f"review_comments[{i}]"
        if not isinstance(f, dict):
            return fail(f"{path}: {loc} must be a mapping")
        for k in REQUIRED_FINDING_KEYS:
            if k not in f:
                return fail(f"{path}: {loc} missing required key '{k}'")
            v = f[k]
            if not isinstance(v, str) or not v.strip():
                return fail(f"{path}: {loc}.{k} must be a non-empty string")
        if f["severity"] not in SEVERITIES:
            return fail(f"{path}: {loc}.severity must be one of {sorted(SEVERITIES)}, got {f['severity']!r}")
        if f["category"] not in categories:
            return fail(f"{path}: {loc}.category must be one of {sorted(categories)}, got {f['category']!r}")
        fid = f["finding_id"]
        if fid in seen_ids:
            return fail(f"{path}: duplicate finding_id {fid!r} at review_comments[{i}] and review_comments[{seen_ids[fid]}]")
        seen_ids[fid] = i

    if verdict == "approve" and findings:
        return fail(
            f"{path}: overall_verdict='approve' requires review_comments: [] (per review prompt); got {len(findings)} review comment(s): "
            f"{[f['finding_id'] for f in findings]}"
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
