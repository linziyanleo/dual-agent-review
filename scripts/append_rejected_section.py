#!/usr/bin/env python3
"""Rewrite the rejected + deferred review sections of a plan file.

Usage: append_rejected_section.py <session_root> <plan_path>

Scans every vN.dispositions.yaml in <session_root>, aggregates rejected and
deferred entries grouped by plan version, and replaces the plan file's two
sections ("## Rejected suggestions (from review)" + "## Deferred suggestions
(from review)") with the fresh aggregate. Idempotent.

Section detection is a line-oriented Markdown scan that respects fenced code
blocks (``` and ~~~) — header lines inside fences are example text and must
not be treated as managed sections.

Deferred high/medium entries are required by validate_dispositions.py to carry
reason + follow_up, so they always render with both fields populated.

If a description can't be looked up (missing finding in the corresponding
findings file), the entry is still emitted with "(description unavailable)" so
audit info is never silently dropped.
"""
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("ABORT: PyYAML not importable", file=sys.stderr)
    sys.exit(1)


REJECTED_HEADER = "## Rejected suggestions (from review)"
DEFERRED_HEADER = "## Deferred suggestions (from review)"


def version_key(name: str) -> int:
    m = re.match(r"^v(\d+)\.dispositions\.ya?ml$", name)
    return int(m.group(1)) if m else 0


def collect_groups(dispo_files: list[Path], session_root: Path, kind: str):
    """Return [(version, [(fid, desc, reason, follow_up), ...]), ...] for dispositions of `kind`."""
    groups: list[tuple[str, list[tuple[str, str, str, str]]]] = []
    for dpath in dispo_files:
        try:
            doc = yaml.safe_load(dpath.read_text(encoding="utf-8"))
        except yaml.YAMLError as e:
            print(f"ABORT: YAML parse error in {dpath}: {e}", file=sys.stderr)
            sys.exit(1)
        if not isinstance(doc, dict):
            continue
        version = doc.get("plan_version_reviewed")
        # Normalize: LLMs often write `plan_version_reviewed: 1` (int) instead of "v1".
        if isinstance(version, int) or (isinstance(version, str) and version.isdigit()):
            version = f"v{version}"
        if not isinstance(version, str):
            continue

        findings_lookup: dict[str, str] = {}
        fpath = session_root / f"{version}.review-comments.yaml"
        if fpath.is_file():
            try:
                fdoc = yaml.safe_load(fpath.read_text(encoding="utf-8"))
                for f in (fdoc.get("review_comments") if isinstance(fdoc, dict) else []) or []:
                    if isinstance(f, dict) and isinstance(f.get("finding_id"), str):
                        desc = f.get("description")
                        findings_lookup[f["finding_id"]] = desc if isinstance(desc, str) else ""
            except yaml.YAMLError:
                pass

        items: list[tuple[str, str, str, str]] = []
        for d in doc.get("dispositions", []) or []:
            if not isinstance(d, dict):
                continue
            if d.get("disposition") != kind:
                continue
            fid = d.get("finding_id", "")
            reason = (d.get("reason") or "").strip()
            follow_up = (d.get("follow_up") or "").strip()
            desc = findings_lookup.get(fid, "(description unavailable)") or "(description unavailable)"
            items.append((fid, desc.strip(), reason, follow_up))
        if items:
            groups.append((version, items))
    return groups


def render_section(header: str, groups, empty_text: str, include_follow_up: bool) -> str:
    if not groups:
        return f"{header}\n\n{empty_text}\n"
    lines = [header, ""]
    for version, items in groups:
        lines.append(f"### From {version} review")
        lines.append("")
        for fid, desc, reason, follow_up in items:
            lines.append(f"- **{fid}** — {desc}")
            label = "Reason deferred" if include_follow_up else "Reason rejected"
            if reason:
                lines.append(f"  - {label}: {reason}")
            if include_follow_up and follow_up:
                lines.append(f"  - Follow-up: {follow_up}")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def _fence_toggle(line: str, current: str | None) -> str | None:
    """Return new fence state after this line.

    `current` is the opening fence marker ("```" or "~~~") if we're inside a
    fence, else None. A line that starts with the same marker (after optional
    leading spaces) closes the fence; any fence marker outside opens one.
    Asymmetric markers (e.g. ``` inside a ~~~ fence) do not close it.
    """
    stripped = line.lstrip(" ")
    if current is None:
        if stripped.startswith("```"):
            return "```"
        if stripped.startswith("~~~"):
            return "~~~"
        return None
    if stripped.startswith(current):
        return None
    return current


def _find_managed_section(lines: list[str], header: str) -> tuple[int, int] | None:
    """Locate the managed section bounded by `header` and the next top-level
    `## ` header outside any fenced code block.

    Returns (start_index, end_index_exclusive) in `lines`, or None if no
    matching header line exists outside a fence.
    """
    fence: str | None = None
    start: int | None = None
    for i, raw in enumerate(lines):
        line = raw.rstrip("\n")
        if start is None:
            if fence is None and line == header:
                start = i
            else:
                fence = _fence_toggle(line, fence)
            continue
        # Once inside the managed section, the next top-level `## ` header
        # outside a fence ends it. Track fence state from the line AFTER the
        # managed header so the header itself doesn't toggle anything.
        fence = _fence_toggle(line, fence)
        if fence is None and line.startswith("## ") and line != header:
            return (start, i)
    if start is not None:
        return (start, len(lines))
    return None


def replace_or_append(text: str, header: str, body: str) -> str:
    lines = text.splitlines(keepends=True)
    span = _find_managed_section(lines, header)
    if span is not None:
        start, end = span
        prefix = "".join(lines[:start])
        suffix = "".join(lines[end:])
        if prefix and not prefix.endswith("\n"):
            prefix += "\n"
        # When a following section exists, preserve the blank-line separator the
        # original regex implementation produced. Without this, second-run output
        # collapses `<body>\n\n## Next` to `<body>\n## Next` and idempotency breaks.
        if suffix:
            body = body.rstrip("\n") + "\n\n"
        return prefix + body + suffix
    if not text.endswith("\n"):
        text += "\n"
    return text + "\n" + body


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: append_rejected_section.py <session_root> <plan_path>", file=sys.stderr)
        return 1
    session_root = Path(sys.argv[1])
    plan_path = Path(sys.argv[2])
    if not plan_path.is_file():
        print(f"ABORT: plan file not found: {plan_path}", file=sys.stderr)
        return 1

    dispo_files = sorted(
        session_root.glob("v*.dispositions.yaml"),
        key=lambda p: version_key(p.name),
    )

    rejected_groups = collect_groups(dispo_files, session_root, "rejected")
    deferred_groups = collect_groups(dispo_files, session_root, "deferred")

    rejected_body = render_section(
        REJECTED_HEADER,
        rejected_groups,
        "(No rejected suggestions across all review rounds. This section is kept as "
        "a contract placeholder so SKILL.md Step 7 always produces a recognisable anchor.)",
        include_follow_up=False,
    )
    deferred_body = render_section(
        DEFERRED_HEADER,
        deferred_groups,
        "(No deferred suggestions across all review rounds. This section is kept as "
        "a contract placeholder so SKILL.md Step 7 always produces a recognisable anchor.)",
        include_follow_up=True,
    )

    text = plan_path.read_text(encoding="utf-8")
    text = replace_or_append(text, REJECTED_HEADER, rejected_body)
    text = replace_or_append(text, DEFERRED_HEADER, deferred_body)
    text = text.rstrip() + "\n"

    plan_path.write_text(text, encoding="utf-8")
    print(
        f"updated review sections in {plan_path} "
        f"(rejected groups: {len(rejected_groups)}, deferred groups: {len(deferred_groups)})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
