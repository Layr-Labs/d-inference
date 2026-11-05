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

This check reads source only and has no type information. An operand is a
Date by its syntax (`Date(...)`, `Date.now`, `addingTimeInterval(...)`,
`startOfDay(for:)`, `date(from:)`, a function declared to return a Date) or by
its name. A bare name takes the type of the declaration in scope: a `let` or
`var` with a Date type or a Date value, or a parameter. Other names are Dates
when the file, or else all shipped source, declares them only as Dates. An
operator passed as a function (`sorted(by: >=)`) has no operand types, so it
is always refused. The check can still miss a comparison. The release build's
binary check (scripts/check-provider-weak-imports.py) is the complete guard.
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
# `name: Date`, `label name: Date` and `var name: Date?`.
_DATE_DECLARATION = re.compile(rf"\b({_IDENT})\s*:\s*{_DATE_TYPE}")
_OTHER_DECLARATION = re.compile(rf"\b({_IDENT})\s*:\s*(?:\[|\(|(?!Date[?!]?(?![A-Za-z0-9_]))[A-Z][A-Za-z0-9_.]*)")
# File-wide evidence for names that no declaration in scope settles. A Date
# followed by a member (`Date().timeIntervalSince(start)`) is that member's
# value, not a Date.
_NO_MEMBER = r"(?![ \t]*[?!]?\.)"
_DATE_VALUE = re.compile(
    rf"\b(?:let|var)\s+({_IDENT})\s*=\s*(?:Date\s*\((?:[^()\n]|\([^()\n]*\))*\){_NO_MEMBER}|"
    rf"Date\.(?:now|distantPast|distantFuture)\b{_NO_MEMBER}|[^=\n]*\.addingTimeInterval\()")
_OTHER_VALUE = re.compile(
    rf"\b(?:let|var)\s+({_IDENT})\s*=\s*(?:-?[0-9.]|\"|\[|true\b|false\b|(?!Date\b)[A-Z][A-Za-z0-9_]*\s*[.(])")
_DATE_FUNCTION = re.compile(
    rf"\bfunc\s+({_IDENT})\s*(?:<[^>]*>)?\((?:[^()]|\([^()]*\))*\)\s*(?:async\s+)?"
    rf"(?:(?:re)?throws(?:\([^()]*\))?\s+)?->\s*{_DATE_TYPE}")
# `let name = value` and `var name = value`, resolved by position.
_BINDING = re.compile(rf"\b(?:let|var)\s+({_IDENT})\s*=(?!=)")
# A bound value that is not a Date: a literal, a type's initializer or a clock's instant.
_OTHER_BINDING = re.compile(
    r"^(?:-?[0-9.]|\"|\[|true\b|false\b|(?!Date\b)[A-Z][A-Za-z0-9_]*(?:<[^>]*>)?\(|"
    r"(?:ContinuousClock|SuspendingClock)\.now\b|DispatchTime\.now\(\))")
_PARAMETER_LIST = re.compile(r"(?:\bfunc\s+[^\s(<]+\s*(?:<[^>]*>)?|\binit[?!]?|\bsubscript)\s*$")
_SIGNATURE_TAIL = re.compile(
    r"(?:(?!\b(?:func|var|let|init|case|subscript|struct|class|enum|extension|protocol)\b)[^{};])*")
_DATE_CONSTANT = re.compile(r"^Date\.(?:now|distantPast|distantFuture)$")
# Foundation members that return a Date: Date.addingTimeInterval,
# Calendar.startOfDay(for:), Calendar.date(...), Calendar.nextDate(...) and
# the date formatters' date(from:).
_DATE_MEMBER_CALLS = {"addingTimeInterval", "startOfDay", "date", "nextDate"}
_LITERAL = re.compile(r"^-?[0-9][0-9_.]*$")
# `ContinuousClock.now` or `Calendar.current`: a member of a type other than Date or Self.
_OTHER_TYPE_MEMBER = re.compile(r"^(?!(?:Date|Self)\.)[A-Z][A-Za-z0-9_]*\.")
_PREFIX = re.compile(r"^(?:(?:try[?!]?|await)\s+)+")
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


def _split_top_level(expression, separator):
    """`expression` split at each `separator` outside brackets."""
    parts, depth, start, i = [], 0, 0, 0
    while i < len(expression):
        c = expression[i]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif depth == 0 and expression.startswith(separator, i):
            parts.append(expression[start:i])
            i += len(separator)
            start = i
            continue
        i += 1
    parts.append(expression[start:])
    return parts


def _trailing_call(operand):
    """`(receiver, name, arguments)` when `operand` ends in a call; name is None for `(...)`."""
    if not operand.endswith(")"):
        return None
    depth = 0
    for k in range(len(operand) - 1, -1, -1):
        if operand[k] == ")":
            depth += 1
        elif operand[k] == "(":
            depth -= 1
            if depth == 0:
                break
    else:
        return None
    called = re.search(rf"({_IDENT})\s*$", operand[:k])
    if not called:
        return operand[:k], None, operand[k + 1:-1]
    return operand[:called.start()], called.group(1), operand[k + 1:-1]


def _open_parenthesis(code, position):
    """The `(` that holds `position` within its brace block, or None."""
    depth = 0
    for k in range(position - 1, -1, -1):
        c = code[k]
        if c in ")]":
            depth += 1
        elif c in "([":
            if depth == 0:
                return k if c == "(" else None
            depth -= 1
        elif c in "{}" and depth == 0:
            return None
    return None


def _close_parenthesis(code, opener):
    depth = 0
    for k in range(opener, len(code)):
        if code[k] == "(":
            depth += 1
        elif code[k] == ")":
            depth -= 1
            if depth == 0:
                return k
    return len(code)


def _declaration_anchor(code, position):
    """Where a typed name at `position` becomes visible.

    A `let` or `var` is visible from itself, a closure parameter in its
    closure, a function parameter in the function body. An argument label or a
    function type's parameter declares nothing: None.
    """
    if re.search(r"\b(?:let|var)\s+$", code[max(0, position - 40):position]):
        return position
    opener = _open_parenthesis(code, position)
    if opener is None:
        return None
    before = code[max(0, opener - 200):opener]
    if before.rstrip().endswith("{"):
        return position
    if not _PARAMETER_LIST.search(before):
        return None
    close = _close_parenthesis(code, opener)
    body = code.find("{", close)
    if body < 0 or not _SIGNATURE_TAIL.fullmatch(code, close + 1, body):
        return None
    return body + 1


def _bound_value(code, start):
    """The value of a binding: to the end of the line or a top-level `,`, `{`, `;`, `else` or `where`."""
    depth, j = 0, start
    while j < len(code):
        c = code[j]
        if c in "([":
            depth += 1
        elif c in ")]":
            if depth == 0:
                break
            depth -= 1
        elif depth == 0 and (c in ",{;\n" or (c == " " and re.match(r" (?:else|where)\b", code[j:j + 7]))):
            break
        j += 1
    return code[start:j].strip()


def _block_ends(code, anchors):
    """For each anchor, the offset of the `}` that closes its innermost brace block."""
    ends, waiting, order, k = {}, [[]], sorted(set(anchors)), 0
    for brace in re.finditer(r"[{}]", code):
        i, c = brace.start(), brace.group(0)
        while k < len(order) and order[k] <= i:
            waiting[-1].append(order[k])
            k += 1
        if c == "{":
            waiting.append([])
        elif c == "}" and len(waiting) > 1:
            for anchor in waiting.pop():
                ends[anchor] = i
    for anchor in [anchor for block in waiting for anchor in block] + order[k:]:
        ends[anchor] = len(code)
    return ends


def _scoped_declarations(code):
    """(anchor, scope end, name, kind) by anchor; kind is "date", "other" or a bound value."""
    found = []
    for pattern, kind in ((_DATE_DECLARATION, "date"), (_OTHER_DECLARATION, "other")):
        for match in pattern.finditer(code):
            anchor = _declaration_anchor(code, match.start())
            if anchor is not None:
                found.append((anchor, match.group(1), kind))
    found += [(m.start(), m.group(1), _bound_value(code, m.end())) for m in _BINDING.finditer(code)]
    ends = _block_ends(code, [anchor for anchor, _, _ in found])
    return sorted(((anchor, ends[anchor], name, kind) for anchor, name, kind in found), key=lambda d: d[0])


def _declared(code):
    dates = set(_DATE_DECLARATION.findall(code)) | set(_DATE_VALUE.findall(code))
    others = set(_OTHER_DECLARATION.findall(code)) | set(_OTHER_VALUE.findall(code))
    return dates, others


class DateNames:
    """Which names are Dates.

    A bare name takes the kind of the nearest declaration in scope. A member,
    or a name that no declaration in scope settles, is a Date in a file that
    declares it only as a Date; elsewhere, when shipped source declares it
    only as a Date.
    """

    def __init__(self, sources):
        self.local, self.scoped = {}, {}
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
        for path, code in sources.items():
            scoped = self.scoped[path] = {}
            for anchor, end, name, kind in _scoped_declarations(code):
                if kind not in ("date", "other"):
                    kind = ("date" if is_date_expression(kind, path, self, anchor)
                            else "other" if _OTHER_BINDING.match(kind) else None)
                scoped.setdefault(name, []).append((anchor, end, kind))

    def is_date(self, path, name, offset=None):
        if offset is not None:
            for anchor, end, kind in reversed(self.scoped[path].get(name, ())):
                if anchor < offset < end:
                    if kind is not None:
                        return kind == "date"
                    break
        local, others = self.local[path]
        return name in local or (name not in others and name in self.shipped)


def is_date_expression(expression, path, names, offset):
    """Whether a bound value is a Date: one Date operand, a branch of `?:` or a side of `??`."""
    expression = _PREFIX.sub("", expression.strip())
    branches = _split_top_level(expression, " ? ")
    if len(branches) > 1:
        return any(is_date_expression(branch, path, names, offset)
                   for branch in _split_top_level(" ? ".join(branches[1:]), " : "))
    sides = _split_top_level(expression, " ?? ")
    if len(sides) > 1:
        return any(is_date_expression(side, path, names, offset) for side in sides)
    return _right_operand(expression, 0) == expression and is_date_operand(expression, path, names, offset)


def is_date_operand(operand, path, names, offset):
    if not operand or _LITERAL.match(operand):
        return False
    stripped = operand.rstrip("?!")
    if _DATE_CONSTANT.match(stripped):
        return True
    call = _trailing_call(stripped)
    if call:
        receiver, name, arguments = call
        if name is None:
            return not receiver and is_date_expression(arguments, path, names, offset)
        if not receiver:
            if name in ("max", "min"):
                return any(is_date_expression(argument, path, names, offset)
                           for argument in _split_top_level(arguments, ","))
            return name == "Date" or name in names.functions
        if not receiver.endswith("."):
            return False
        # `Darwin.read(...)` is another type's function, not a Date function of the same name.
        return name in _DATE_MEMBER_CALLS or (name in names.functions and not _OTHER_TYPE_MEMBER.match(receiver))
    if _OTHER_TYPE_MEMBER.match(stripped):
        return False
    bare = re.fullmatch(_IDENT, stripped) is not None
    return names.is_date(path, _last_name(stripped), offset if bare else None)


def _operator_reference(code, match):
    """Whether `>=` or `<=` stands alone as a function argument, as in `sorted(by: >=)`."""
    before = code[max(0, match.start() - 40):match.start()].rstrip()[-1:]
    after = code[match.end():match.end() + 40].lstrip()[:1]
    return before in ("(", ",", ":") and after in (")", ",")


def findings(files):
    """(path, line, text) for each Date `>=` or `<=` in the given Swift files."""
    sources = {path: strip_comments_and_strings(path.read_text(encoding="utf-8")) for path in files}
    names = DateNames(sources)
    found = []
    for path, code in sources.items():
        for match in _OPERATOR.finditer(code):
            left = _left_operand(code, match.start())
            right = _right_operand(code, match.end())
            line = code.count("\n", 0, match.start()) + 1
            if not left and not right and _operator_reference(code, match):
                found.append((path, line, f"{match.group(1)} passed as a function"))
                continue
            dates = [is_date_operand(side, path, names, match.start()) for side in (left, right)]
            # Both operands of Date's operators are Dates.
            if any(_LITERAL.match(side) or (_OTHER_TYPE_MEMBER.match(side) and not date)
                   for side, date in zip((left, right), dates)):
                continue
            if any(dates):
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
