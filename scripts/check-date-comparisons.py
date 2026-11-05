#!/usr/bin/env python3
"""Refuse `>=` and `<=` between Foundation Dates in shipped Swift source.

SDK 27.2 declares Foundation's `Date.>=` and `Date.<=` with
`@backDeployed(before: macOS 27.2)`. Swift 6.4.2 compiles each such
comparison into a call through a weak import of Foundation's symbol, guarded
by an OS version check. Pre-release macOS 27.2 builds (26B5091g) pass that
check but do not export the symbols, so the call jumps to address 0.
`<`, `>`, `==` and `timeIntervalSince(_:)` are not back-deployed: write
`a.timeIntervalSince(b) >= 0` for `a >= b` and `a.timeIntervalSince(b) <= 0`
for `a <= b`.

This check reads source only and has no type information. It finds an operand
that is a Date by its syntax (`Date()`, `addingTimeInterval(...)`) or by a name
that the file, or else all shipped source, declares only as a Date. It can miss
a comparison. The release build's binary check
(scripts/check-provider-weak-imports.py) is the complete guard.
"""
import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SHIPPED_SOURCES = (
    "provider-swift/Sources",
    "libs/darkbloom-cluster/Sources",
    "libs/darkbloom-cluster-worker/Sources",
)

_IDENT = r"[A-Za-z_][A-Za-z0-9_]*"
_DATE_TYPE = r"Date[?!]?(?![A-Za-z0-9_])"
# `name: Date`, `label name: Date`, `var name: Date?` and `let name = Date(...)`.
_DATE_DECLARATION = re.compile(rf"\b({_IDENT})\s*:\s*{_DATE_TYPE}")
_DATE_VALUE = re.compile(
    rf"\b(?:let|var)\s+({_IDENT})\s*=\s*(?:Date\s*\(|Date\.now\b|[^=\n]*\.addingTimeInterval\()")
_DATE_FUNCTION = re.compile(rf"\bfunc\s+({_IDENT})\s*(?:<[^>]*>)?\([^)]*\)\s*(?:async\s+)?(?:throws\s+)?->\s*{_DATE_TYPE}")
_OTHER_DECLARATION = re.compile(rf"\b({_IDENT})\s*:\s*(?:\[|\(|(?!Date[?!]?(?![A-Za-z0-9_]))[A-Z][A-Za-z0-9_.]*)")
_OTHER_VALUE = re.compile(
    rf"\b(?:let|var)\s+({_IDENT})\s*=\s*(?:-?[0-9.]|\"|\[|true\b|false\b|(?!Date\b)[A-Z][A-Za-z0-9_]*\s*[.(])")
# An operand whose value is a Date by its syntax: a Date initializer or
# constant, or a chain that ends in a call that returns a Date.
_DATE_EXPRESSION = re.compile(
    r"^(?:Date\s*\([^()]*\)|Date\.(?:now|distantPast|distantFuture))$|"
    r"\.addingTimeInterval\([^()]*\)$|\bstartOfDay\(for:[^()]*(?:\([^()]*\))?[^()]*\)$")
_LITERAL = re.compile(r"^-?[0-9][0-9_.]*$")
# `ContinuousClock.now` or `Self.limit`: a member of a type other than Date.
_OTHER_TYPE_MEMBER = re.compile(r"^(?!Date\.)[A-Z][A-Za-z0-9_]*\.")
# Foundation's DateInterval keeps its bounds as Dates.
_DATE_INTERVAL_MEMBERS = {"start", "end"}
_OPERATOR = re.compile(r"(?<![<>=!])(>=|<=)(?![=<>])")
_KEYWORDS = {"self", "Self", "try", "await", "return", "in", "if", "guard", "while", "let", "var", "case", "where"}


def strip_comments_and_strings(text):
    """Blank comments and string literal contents, keeping offsets and lines."""
    out = list(text)
    i, n = 0, len(text)

    def blank(start, end):
        for k in range(start, end):
            if out[k] != "\n":
                out[k] = " "

    while i < n:
        if text.startswith("//", i):
            end = text.find("\n", i)
            end = n if end < 0 else end
            blank(i, end)
            i = end
        elif text.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if text.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                elif text.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            blank(i, j)
            i = j
        elif text.startswith('"""', i):
            end = text.find('"""', i + 3)
            end = n if end < 0 else end + 3
            blank(i + 3, max(i + 3, end - 3))
            i = end
        elif text[i] == '"':
            j = i + 1
            while j < n and text[j] not in '"\n':
                j += 2 if text[j] == "\\" else 1
            blank(i + 1, min(j, n))
            i = j + 1
        else:
            i += 1
    return "".join(out)


def _left_operand(code, end):
    """The postfix expression that ends at `end` (exclusive)."""
    j = end
    while j > 0 and code[j - 1] in " \t":
        j -= 1
    stop = j
    while j > 0:
        c = code[j - 1]
        if c in ")]":
            depth, k = 0, j - 1
            while k >= 0:
                if code[k] in ")]":
                    depth += 1
                elif code[k] in "([":
                    depth -= 1
                    if depth == 0:
                        break
                k -= 1
            j = max(k, 0)
        elif c.isalnum() or c in "_.$?!":
            j -= 1
        else:
            break
    return code[j:stop]


def _right_operand(code, start):
    """The prefix and postfix expression that starts at `start`."""
    n = len(code)
    j = start
    while j < n and code[j] in " \t":
        j += 1
    begin = j
    while j < n:
        c = code[j]
        if c in "([":
            depth, k = 0, j
            while k < n:
                if code[k] in "([":
                    depth += 1
                elif code[k] in ")]":
                    depth -= 1
                    if depth == 0:
                        break
                k += 1
            j = k + 1
        elif c.isalnum() or c in "_.$?!":
            j += 1
        else:
            break
    return code[begin:j]


def _last_name(operand):
    """The member or variable an operand reads: `$0.at` reads `at`."""
    names = [m.group(0) for m in re.finditer(_IDENT, re.sub(r"\([^()]*\)|\[[^\[\]]*\]", "", operand))]
    names = [name for name in names if name not in _KEYWORDS]
    return names[-1] if names else None


def _declared(code):
    dates = set(_DATE_DECLARATION.findall(code)) | set(_DATE_VALUE.findall(code))
    others = set(_OTHER_DECLARATION.findall(code)) | set(_OTHER_VALUE.findall(code))
    return dates, others


class DateNames:
    """Which names are Dates, file by file.

    A name is a Date in a file that declares it only as a Date. Elsewhere it
    is a Date when shipped source declares it only as a Date.
    """

    def __init__(self, sources):
        self.local = {}
        all_dates, all_others, self.functions = set(), set(), set()
        for path, code in sources.items():
            dates, others = _declared(code)
            local = dates - others
            if "DateInterval" in code:
                local |= _DATE_INTERVAL_MEMBERS - others
            self.local[path] = (local, others)
            all_dates |= dates
            all_others |= others
            self.functions.update(_DATE_FUNCTION.findall(code))
        self.shipped = all_dates - all_others

    def is_date(self, path, name):
        local, others = self.local[path]
        return name in local or (name not in others and name in self.shipped)


def is_date_operand(operand, path, names):
    if not operand or _LITERAL.match(operand):
        return False
    stripped = operand.rstrip("?!")
    if _DATE_EXPRESSION.search(stripped):
        return True
    if _OTHER_TYPE_MEMBER.match(stripped):
        return False
    if stripped.endswith(")"):
        called = re.search(rf"({_IDENT})\((?:[^()]|\([^()]*\))*\)$", stripped)
        return bool(called) and called.group(1) in names.functions
    return names.is_date(path, _last_name(stripped))


def findings(files):
    """(path, line, text) for each Date `>=` or `<=` in the given Swift files."""
    sources = {path: strip_comments_and_strings(path.read_text(encoding="utf-8")) for path in files}
    names = DateNames(sources)
    found = []
    for path, code in sources.items():
        for match in _OPERATOR.finditer(code):
            left = _left_operand(code, match.start())
            right = _right_operand(code, match.end())
            # Both operands of Date's operators are Dates.
            if any(_LITERAL.match(side) or _OTHER_TYPE_MEMBER.match(side) for side in (left, right)):
                continue
            if is_date_operand(left, path, names) or is_date_operand(right, path, names):
                line = code.count("\n", 0, match.start()) + 1
                found.append((path, line, f"{left} {match.group(1)} {right}"))
    return found


def shipped_swift_files(root):
    return sorted(p for base in SHIPPED_SOURCES for p in (root / base).rglob("*.swift"))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("files", nargs="*", type=Path, help="Swift files (default: every shipped source)")
    args = parser.parse_args(argv)
    files = args.files or shipped_swift_files(args.root)
    found = findings(files)
    for path, line, text in found:
        shown = path.relative_to(args.root) if path.is_relative_to(args.root) else path
        print(f"{shown}:{line}: Date comparison `{text}` is back-deployed in SDK 27.2; "
              "write a.timeIntervalSince(b) >= 0 or <= 0", file=sys.stderr)
    if found:
        print(f"{len(found)} back-deployed Date comparison(s); see scripts/check-date-comparisons.py", file=sys.stderr)
        return 1
    print(f"No back-deployed Date comparisons in {len(files)} Swift files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
