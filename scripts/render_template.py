#!/usr/bin/env python3
"""Render a prompt template by replacing {{KEY}} placeholders.

Usage: render_template.py <template_path> KEY=value [KEY=value ...]

Keys ending in _FILE trigger file-injection: the suffix is stripped to derive
the placeholder name (e.g. SPEC_CONTEXT_FILE -> {{SPEC_CONTEXT}}), the file at
<value> is read and its content replaces the placeholder.

Budget: file content is truncated to N lines (default 200, override via
DAR_<PLACEHOLDER>_MAX_LINES env var, e.g. DAR_SPEC_CONTEXT_MAX_LINES=300).

After all replacements, asserts no unresolved {{...}} tokens remain.
"""
import os
import re
import sys
from pathlib import Path

MAX_LINES_DEFAULT = 200


def read_with_budget(file_path: Path, placeholder_name: str) -> str:
    if not file_path.is_file():
        print(f"ABORT: _FILE injection target not found: {file_path}", file=sys.stderr)
        sys.exit(1)
    lines = file_path.read_text(encoding="utf-8").splitlines(keepends=True)
    env_key = f"DAR_{placeholder_name}_MAX_LINES"
    max_lines = int(os.environ.get(env_key, MAX_LINES_DEFAULT))
    if len(lines) > max_lines:
        truncated = "".join(lines[:max_lines])
        truncated += f"\n... (truncated at {max_lines} lines)\n"
        return truncated
    return "".join(lines)


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: render_template.py <template> KEY=value ...", file=sys.stderr)
        return 2
    template_path = Path(sys.argv[1])
    if not template_path.is_file():
        print(f"ABORT: template not found: {template_path}", file=sys.stderr)
        return 1

    pairs: list[tuple[str, str]] = []
    file_pairs: list[tuple[str, str]] = []

    for raw in sys.argv[2:]:
        if "=" not in raw:
            print(f"ABORT: arg {raw!r} is not KEY=value", file=sys.stderr)
            return 2
        k, v = raw.split("=", 1)
        if not k:
            print(f"ABORT: empty key in {raw!r}", file=sys.stderr)
            return 2
        if k.endswith("_FILE"):
            placeholder = k[: -len("_FILE")]
            file_pairs.append((placeholder, v))
        else:
            pairs.append((k, v))

    text = template_path.read_text(encoding="utf-8")

    for placeholder, file_path_str in file_pairs:
        content = read_with_budget(Path(file_path_str), placeholder)
        text = text.replace("{{" + placeholder + "}}", content)

    for k, v in pairs:
        text = text.replace("{{" + k + "}}", v)

    unresolved = re.findall(r"\{\{[A-Z_]+\}\}", text)
    if unresolved:
        print(f"ABORT: unresolved placeholder(s) in rendered output: {', '.join(sorted(set(unresolved)))}", file=sys.stderr)
        return 1

    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
