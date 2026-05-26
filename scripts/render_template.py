#!/usr/bin/env python3
"""Render a prompt template by replacing {{KEY}} placeholders.

Usage: render_template.py <template_path> KEY=value [KEY=value ...]

Uses str.replace (no regex, no shell expansion), so values may contain any character
except embedded NUL (which argv cannot carry anyway). Output goes to stdout.
"""
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: render_template.py <template> KEY=value ...", file=sys.stderr)
        return 2
    template_path = Path(sys.argv[1])
    if not template_path.is_file():
        print(f"ABORT: template not found: {template_path}", file=sys.stderr)
        return 1

    pairs: list[tuple[str, str]] = []
    for raw in sys.argv[2:]:
        if "=" not in raw:
            print(f"ABORT: arg {raw!r} is not KEY=value", file=sys.stderr)
            return 2
        k, v = raw.split("=", 1)
        if not k:
            print(f"ABORT: empty key in {raw!r}", file=sys.stderr)
            return 2
        pairs.append((k, v))

    text = template_path.read_text(encoding="utf-8")
    for k, v in pairs:
        text = text.replace("{{" + k + "}}", v)

    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
