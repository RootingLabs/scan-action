#!/usr/bin/env python3
"""Apply one finding's fix to the checked-out repo.

Reads a single fix object (JSON) with ``code_locations: [{path, fix_before,
fix_after}]`` and replaces the first occurrence of each ``fix_before`` anchor
with ``fix_after`` in the file at ``path``. Anchors that are not found are
skipped (the file drifted since the scan) rather than guessed, so a stale
location never corrupts a file. Prints the paths that actually changed.
"""

import json
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: apply_fix.py <fix.json>", file=sys.stderr)
        return 2
    with open(sys.argv[1], encoding="utf-8") as handle:
        fix = json.load(handle)

    changed: list[str] = []
    for loc in fix.get("code_locations", []):
        path = loc.get("path")
        before = loc.get("fix_before")
        after = loc.get("fix_after")
        if not path or not before or after is None:
            continue
        try:
            with open(path, encoding="utf-8") as handle:
                content = handle.read()
        except OSError:
            continue
        if before not in content:
            continue
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(content.replace(before, after, 1))
        changed.append(path)

    print("\n".join(changed))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
