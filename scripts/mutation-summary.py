#!/usr/bin/env python3
"""Print a Markdown summary of a gremlins mutation report.

Usage: scripts/mutation-summary.py <report.json>

The score is killed / (killed + lived). Timed-out, not-viable, and not-covered
mutants do not count in the score. The script never judges the score. It exits
non-zero only when the report is missing or unreadable.
"""
import json
import sys
from collections import Counter


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    path = argv[1]
    try:
        with open(path, encoding="utf-8") as handle:
            report = json.load(handle)
    except (OSError, ValueError) as err:
        print(f"no mutation report at {path}: {err}", file=sys.stderr)
        print("The run failed or used its whole time budget. Read registry.txt.", file=sys.stderr)
        return 1

    counts: Counter[str] = Counter()
    lived: list[tuple[str, int, int, str]] = []
    for entry in report.get("files") or []:
        name = entry["file_name"]
        for mutation in entry.get("mutations") or []:
            counts[mutation["status"]] += 1
            if mutation["status"] == "LIVED":
                lived.append((name, mutation["line"], mutation["column"], mutation["type"]))

    killed = counts["KILLED"]
    tested = killed + counts["LIVED"]
    score = f"{100 * killed / tested:.1f}%" if tested else "n/a"

    print("## Mutation report: coordinator/registry routing files")
    print()
    print(f"Score (killed / (killed + lived)): **{score}**")
    print()
    print("| Status | Count |")
    print("|---|---:|")
    for status in ("KILLED", "LIVED", "TIMED OUT", "NOT COVERED", "NOT VIABLE"):
        print(f"| {status} | {counts[status]} |")
    print(f"| total | {sum(counts.values())} |")
    print()
    print(f"Run time: {report.get('elapsed_time', 0):.0f} s. Report only: the score does not fail any check.")
    print()
    print(f"### Surviving mutants ({len(lived)})")
    print()
    for name, line, column, kind in sorted(lived):
        print(f"- `{name}:{line}:{column}` {kind}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
