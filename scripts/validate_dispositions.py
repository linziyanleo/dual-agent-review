#!/usr/bin/env python3
"""Validate a dispositions file against its findings file.

Usage: validate_dispositions.py <findings_path> <dispositions_path>

Exit 0 on success. Exit 1 with the first error on stdout (single line, embeddable).

Checks (executed top to bottom; first failure wins):
  0. findings file is itself valid per validate_review_comments.py (gate; rejects dup
     finding_id at the producer boundary before anything else runs).
  1. Every finding has a disposition.
  2. disposition is one of incorporated / rejected / deferred.
  3. rejected entries have a non-empty reason.
  4. set(finding_ids in findings) == set(finding_ids in dispositions) (strict).
  5. Dispositions file contains no duplicate finding_id.
  6. total_review_comments equals the actual number of disposition entries.
  7. plan_version_reviewed matches the file name (vN.dispositions.yaml -> "vN").
  8. incorporated entries have a non-empty plan_change_summary.
  9. deferred is rejected outright for high/medium severity findings — use
     disposition: rejected with a substantive reason that points to where the
     work is tracked externally instead. Low/nit deferrals stay lightweight.
"""
import re
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("ABORT: PyYAML not importable", file=sys.stderr)
    sys.exit(1)


DISPOSITIONS = {"incorporated", "rejected", "deferred"}


def fail(msg: str) -> int:
    print(msg)
    return 1


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: validate_dispositions.py <findings_path> <dispositions_path>", file=sys.stderr)
        return 1
    findings_path = Path(sys.argv[1])
    dispositions_path = Path(sys.argv[2])

    # Gate (check 0): findings must be schema-valid before we judge dispositions.
    validator = Path(__file__).with_name("validate_review_comments.py")
    result = subprocess.run(
        [sys.executable, str(validator), str(findings_path)],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        # validate_review_comments.py prints a single-line error to stdout; surface it verbatim.
        err = (result.stdout or result.stderr).strip()
        return fail(f"{dispositions_path}: upstream findings invalid -> {err}")

    if not dispositions_path.is_file():
        return fail(f"{dispositions_path}: file does not exist")

    try:
        findings_doc = yaml.safe_load(findings_path.read_text(encoding="utf-8"))
        dispositions_doc = yaml.safe_load(dispositions_path.read_text(encoding="utf-8"))
    except yaml.YAMLError as e:
        return fail(f"{dispositions_path}: YAML parse error: {e}")

    if not isinstance(dispositions_doc, dict):
        return fail(f"{dispositions_path}: top-level must be a mapping")

    finding_ids = [f["finding_id"] for f in findings_doc.get("review_comments", [])]
    severity_by_id = {f["finding_id"]: f["severity"] for f in findings_doc.get("review_comments", [])}
    dispositions = dispositions_doc.get("dispositions")
    if not isinstance(dispositions, list):
        return fail(f"{dispositions_path}: dispositions must be a list")

    # Check 5: dispositions internal duplicate.
    seen: dict[str, int] = {}
    for i, d in enumerate(dispositions):
        if not isinstance(d, dict) or "finding_id" not in d:
            return fail(f"{dispositions_path}: dispositions[{i}] missing finding_id")
        fid = d["finding_id"]
        if fid in seen:
            return fail(f"{dispositions_path}: duplicate finding_id {fid!r} at dispositions[{i}] and [{seen[fid]}]")
        seen[fid] = i

    # Check 4: strict set equality.
    findings_set = set(finding_ids)
    dispositions_set = set(seen.keys())
    missing = findings_set - dispositions_set
    extra = dispositions_set - findings_set
    if missing:
        return fail(f"{dispositions_path}: missing disposition for finding_id(s) {sorted(missing)}")
    if extra:
        return fail(f"{dispositions_path}: disposition references unknown finding_id(s) {sorted(extra)}")

    # Check 6: total_review_comments.
    declared_total = dispositions_doc.get("total_review_comments")
    if declared_total != len(dispositions):
        return fail(
            f"{dispositions_path}: total_review_comments={declared_total} but actual={len(dispositions)}"
        )

    # Check 7: plan_version_reviewed matches file name.
    m = re.match(r"^(v\d+)\.dispositions\.ya?ml$", dispositions_path.name)
    if not m:
        return fail(f"{dispositions_path}: file name must match vN.dispositions.yaml")
    expected_version = m.group(1)
    declared_version = dispositions_doc.get("plan_version_reviewed")
    if declared_version != expected_version:
        return fail(
            f"{dispositions_path}: plan_version_reviewed={declared_version!r} but file name implies {expected_version!r}"
        )

    # Checks 1, 2, 3, 8: per-entry semantics.
    for i, d in enumerate(dispositions):
        loc = f"dispositions[{i}] (finding_id={d['finding_id']!r})"
        disp = d.get("disposition")
        if disp not in DISPOSITIONS:
            return fail(f"{dispositions_path}: {loc} disposition must be one of {sorted(DISPOSITIONS)}, got {disp!r}")
        if disp == "rejected":
            reason = d.get("reason")
            if not isinstance(reason, str) or not reason.strip():
                return fail(f"{dispositions_path}: {loc} rejected disposition requires non-empty reason")
        if disp == "incorporated":
            summary = d.get("plan_change_summary")
            if not isinstance(summary, str) or not summary.strip():
                return fail(f"{dispositions_path}: {loc} incorporated disposition requires non-empty plan_change_summary")
        if disp == "deferred" and severity_by_id.get(d["finding_id"]) in {"high", "medium"}:
            return fail(
                f"{dispositions_path}: {loc} disposition='deferred' is not allowed for high/medium "
                f"severity findings; use disposition='rejected' with a substantive reason that "
                f"points to where the work is tracked externally (ticket id, doc link, or owner+deadline)"
            )

    return 0


if __name__ == "__main__":
    sys.exit(main())
