#!/usr/bin/env python3
"""Refuse a provider binary that imports a Foundation symbol a served macOS lacks.

SDK 27.2 declares Foundation's `Date.>=` and `Date.<=` with
`@backDeployed(before: macOS 27.2)`. Swift 6.4.2 compiles each such comparison
into a weak import of the symbol behind an OS version check. Pre-release macOS
27.2 builds (26B5091g) pass the check but do not export the symbols, so the
weak bind is NULL and the call jumps to address 0. Provider builds made this
way crashed in a loop on such a Mac. scripts/check-date-comparisons.py keeps
the pattern out of source; this check reads the built binaries and is the
complete guard.
"""
import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path

# Foundation symbols that some served macOS 27.2 builds do not export.
MISSING_ON_SERVED_MACOS = {
    "_$s10Foundation4DateV2geoiySbAC_ACtFZ": "static Date.>= (back-deployed before macOS 27.2)",
    "_$s10Foundation4DateV2leoiySbAC_ACtFZ": "static Date.<= (back-deployed before macOS 27.2)",
}

# `nm -m` prints an imported symbol as
# `(undefined) [weak ]external <symbol> (from <library>)`.
_UNDEFINED = re.compile(r"^\s*\(undefined\)\s+(?:weak\s+)?external\s+(\S+)")
# `otool -tV` prints `<symbol>:` above each function's instructions.
_LABEL = re.compile(r"^([^0-9\s].*):$")


def run_tool(arguments):
    return subprocess.run(arguments, check=True, capture_output=True, text=True).stdout


def refused_imports(nm_output):
    """The refused symbols that a `nm -m` listing imports, in listing order."""
    found = []
    for line in nm_output.splitlines():
        match = _UNDEFINED.match(line)
        if match and match.group(1) in MISSING_ON_SERVED_MACOS and match.group(1) not in found:
            found.append(match.group(1))
    return found


def referencing_functions(disassembly, symbols):
    """The functions in an `otool -tV` listing whose code names one of `symbols`."""
    functions, current = [], None
    for line in disassembly.splitlines():
        label = _LABEL.match(line)
        if label:
            current = label.group(1)
        elif current and current not in functions and any(symbol in line for symbol in symbols):
            functions.append(current)
    return functions


def demangle(names):
    tool = shutil.which("xcrun")
    if not tool or not names:
        return names
    try:
        result = subprocess.run([tool, "swift-demangle", "--simplified"], input="\n".join(names) + "\n",
                                check=True, capture_output=True, text=True)
    except (OSError, subprocess.CalledProcessError):
        return names
    demangled = result.stdout.splitlines()
    return demangled if len(demangled) == len(names) else names


def check(binary):
    """Messages for each refused import in `binary`; none when it is clean."""
    symbols = refused_imports(run_tool(["nm", "-m", str(binary)]))
    if not symbols:
        return []
    messages = [f"{binary}: imports {symbol}, {MISSING_ON_SERVED_MACOS[symbol]}" for symbol in symbols]
    functions = referencing_functions(run_tool(["otool", "-tV", str(binary)]), symbols)
    messages += [f"{binary}: called from {name}" for name in demangle(functions)]
    return messages


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("binaries", nargs="+", type=Path)
    args = parser.parse_args(argv)
    failed = False
    for binary in args.binaries:
        if not binary.is_file():
            print(f"::error::{binary}: no such binary", file=sys.stderr)
            failed = True
            continue
        messages = check(binary)
        for message in messages:
            print(f"::error::{message}", file=sys.stderr)
        if messages:
            failed = True
        else:
            print(f"{binary}: no Foundation import that a served macOS lacks")
    if failed:
        print("Replace each Date >= or <= with a.timeIntervalSince(b) >= 0 or <= 0 "
              "(scripts/check-date-comparisons.py)", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
