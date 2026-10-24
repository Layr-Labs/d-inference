#!/usr/bin/env python3
"""Validate and render changelog fragments without modifying repository files."""

import argparse
from datetime import date
from pathlib import Path
import re
import sys


FILENAME = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*\.md")
VERSION = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)")


def headings(text: str, source: str):
    """Recognize section headings, excluding fenced and indented code."""
    fence = ""
    previous = ""
    for number, line in enumerate(text.splitlines(), 1):
        marker = re.match(r" {0,3}(`{3,}|~{3,})(.*)$", line)
        if fence:
            if (marker and marker[1][0] == fence[0]
                    and len(marker[1]) >= len(fence) and not marker[2].strip()):
                fence = ""
            continue
        if marker and (marker[1][0] == "~" or "`" not in marker[2]):
            fence = marker[1]
            previous = ""
            continue
        match = re.match(r" {0,3}(#{1,6})(?:[ \t]+(.*))?$", line)
        if match:
            title = re.sub(r"(?:^|[ \t]+)#+[ \t]*$", "", match[2] or "").strip()
            yield number, len(match[1]), title
            previous = ""
        elif previous and re.fullmatch(r" {0,3}(=+|-+)[ \t]*", line):
            yield number - 1, 1 if line.lstrip().startswith("=") else 2, previous
            previous = ""
        else:
            previous = (line.strip() if line and not re.match(
                r"(?: {4}|\t| {0,3}(?:[-+*][ \t]|[0-9]+[.)][ \t]|>))", line
            ) else "")
    if fence:
        raise ValueError(f"{source}: unclosed fenced code block")


def load_fragments(root: Path) -> dict[str, str]:
    directory = root / "changelog.d"
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError("changelog.d must be a regular directory")
    fragments = {}
    topics = {}
    for path in sorted(directory.iterdir()):
        source = f"changelog.d/{path.name}"
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"{source}: must be a regular file, not a symlink")
        if path.name == "README.md":
            continue
        if not FILENAME.fullmatch(path.name):
            raise ValueError(f"{source}: expected a lowercase kebab-case .md filename")
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except UnicodeError:
            raise ValueError(f"{source}: invalid UTF-8") from None
        nonempty = [i for i, line in enumerate(lines) if line.strip()]
        if not nonempty:
            raise ValueError(f"{source}: fragment is blank")
        lines = lines[nonempty[0]:nonempty[-1] + 1]
        if not re.fullmatch(r"###[ \t]+\S.*", lines[0]):
            raise ValueError(f"{source}: first nonempty line must be '### Concise topic'")
        if len(lines) < 3 or lines[1].strip():
            raise ValueError(f"{source}: topic needs a blank line followed by a body")
        text = "\n".join(lines)
        if re.search(r"(?m)^[ \t]*(?:<{7}|>{7}|\|{7}|={7,}[ \t]*$)", text):
            raise ValueError(f"{source}: merge conflict marker")
        sections = list(headings(text, source))
        topic = " ".join(sections[0][2].split()).casefold()
        if not topic:
            raise ValueError(f"{source}: topic must not be empty")
        for number, level, _ in sections[1:]:
            if level <= 3:
                raise ValueError(
                    f"{source}:{number + nonempty[0]}: extra level {level} section heading")
        if topic in topics:
            raise ValueError(f"{source}: duplicate topic heading in {topics[topic]}")
        topics[topic] = source
        fragments[path.name] = text
    return fragments


def section(title: str, fragments) -> str:
    return "\n\n".join([f"## {title}", *fragments]) + "\n"


def preview(root: Path) -> str:
    return section("Unreleased", load_fragments(root).values())


def render(root: Path, version: str, release_date: str, filenames=()) -> str:
    if not VERSION.fullmatch(version):
        raise ValueError("version must be X.Y.Z with no prefix, suffix, or leading zeros")
    try:
        if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", release_date):
            raise ValueError
        date.fromisoformat(release_date)
    except ValueError:
        raise ValueError("date must be a valid YYYY-MM-DD calendar date") from None
    fragments = load_fragments(root)
    if len(set(filenames)) != len(filenames):
        raise ValueError("fragment selection contains duplicate filenames")
    for name in filenames:
        if not FILENAME.fullmatch(name) or name not in fragments:
            raise ValueError(f"unknown fragment basename: {name!r}")
    selected = [fragments[name] for name in sorted(filenames or fragments)]
    if not selected:
        raise ValueError("no pending changelog fragments to render")
    history = (root / "CHANGELOG.md").read_text(encoding="utf-8")
    for _, level, title in headings(history, "CHANGELOG.md"):
        if level == 2 and re.match(rf"v?{re.escape(version)}(?:[ \t(:]|$)", title):
            raise ValueError(f"version {version} already appears in CHANGELOG.md")
    return section(f"v{version} - {release_date}", selected)


def main(argv=None, root: Path = Path(__file__).resolve().parents[1]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check", help="validate all pending fragments")
    commands.add_parser("preview", help="print the pending Unreleased section")
    release = commands.add_parser("render", help="print a release section for review")
    release.add_argument("--version", required=True, metavar="X.Y.Z")
    release.add_argument("--date", required=True, metavar="YYYY-MM-DD")
    release.add_argument("fragments", nargs="*", metavar="NAME.md",
                         help="basenames from changelog.d; default: all fragments")
    args = parser.parse_args(argv)
    try:
        if args.command == "check":
            print(f"changelog: {len(load_fragments(root))} valid fragment(s)")
        elif args.command == "preview":
            print(preview(root), end="")
        else:
            print(render(root, args.version, args.date, args.fragments), end="")
    except (OSError, UnicodeError, ValueError) as exc:
        print(f"changelog: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
