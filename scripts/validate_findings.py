#!/usr/bin/env python3
"""Validate a Codex findings YAML against the dual-agent-review schema.

Usage: validate_findings.py <findings_path>

Exit 0 on success (no stdout). Exit 1 with a single human-readable error line on
stdout — the line is embedded directly into the retry prompt template, so it must
stand alone and name the file + the broken field path.
"""
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("ABORT: PyYAML not importable", file=sys.stderr)
    sys.exit(1)


VERDICTS = {"approve", "request_changes", "block"}
SEVERITIES = {"high", "medium", "low", "nit"}
CATEGORIES = {
    "correctness", "security", "performance", "maintainability",
    "scope", "testing", "unclear-requirements", "other",
}
REQUIRED_FINDING_KEYS = (
    "finding_id", "severity", "category", "location",
    "description", "suggested_change", "rationale",
)


def fail(msg: str) -> int:
    print(msg)
    return 1


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: validate_findings.py <findings_path>", file=sys.stderr)
        return 1
    path = Path(sys.argv[1])
    if not path.is_file():
        return fail(f"{path}: file does not exist")

    raw = path.read_text(encoding="utf-8")
    if not raw.strip():
        return fail(f"{path}: file is empty")

    try:
        doc = yaml.safe_load(raw)
    except yaml.YAMLError as e:
        return fail(f"{path}: YAML parse error: {e}")

    if not isinstance(doc, dict):
        return fail(f"{path}: top-level must be a mapping")

    verdict = doc.get("overall_verdict")
    if verdict not in VERDICTS:
        return fail(f"{path}: overall_verdict must be one of {sorted(VERDICTS)}, got {verdict!r}")

    if not isinstance(doc.get("summary"), str) or not doc["summary"].strip():
        return fail(f"{path}: summary must be a non-empty string")

    findings = doc.get("findings")
    if not isinstance(findings, list):
        return fail(f"{path}: findings must be a list (got {type(findings).__name__})")

    seen_ids: dict[str, int] = {}
    for i, f in enumerate(findings):
        loc = f"findings[{i}]"
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
        if f["category"] not in CATEGORIES:
            return fail(f"{path}: {loc}.category must be one of {sorted(CATEGORIES)}, got {f['category']!r}")
        fid = f["finding_id"]
        if fid in seen_ids:
            return fail(f"{path}: duplicate finding_id {fid!r} at findings[{i}] and findings[{seen_ids[fid]}]")
        seen_ids[fid] = i

    # Prompt mandates `overall_verdict: approve` means `findings: []` — don't
    # invent nits to fill space. Enforce here so the contract isn't a vibe.
    if verdict == "approve" and findings:
        return fail(
            f"{path}: overall_verdict='approve' requires findings: [] (per review prompt); got {len(findings)} finding(s): "
            f"{[f['finding_id'] for f in findings]}"
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
