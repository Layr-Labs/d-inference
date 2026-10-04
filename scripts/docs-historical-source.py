#!/usr/bin/env python3
"""Extract Markdown metadata/links and validate frozen source provenance."""

from functools import lru_cache
from pathlib import Path
import posixpath
import re
import subprocess
import sys


def git(*arguments):
    return subprocess.run(
        ["git", "-c", "log.showSignature=false", *arguments],
        text=True, capture_output=True, check=True,
    ).stdout


def parent_document(parent, revision, document):
    # Compare each actual parent, with rename detection over the whole tree.
    # Copies/additions begin a new record rather than inheriting its history.
    tokens = iter(git("diff-tree", "--no-commit-id", "-r", "-M", "--name-status", "-z",
                      parent, revision).split("\0"))
    for token in tokens:
        if token:
            old = next(tokens)
            new = next(tokens) if token[0] in "RC" else old
            if new == document:
                return None if token[0] in "AC" else old
    return document


@lru_cache(maxsize=None)
def document_text(revision, document):
    return git("show", f"{revision}:{document}")


def document_history(record, path):
    revision = "HEAD"
    while True:
        # Skip unchanged ordinary commits, but retain merge snapshots even
        # when default --follow history omits their file-status entries.
        revision = git("log", "-1", "--full-history", "--format=%H",
                       revision, "--", record).strip()
        if not revision:
            return
        text = document_text(revision, record)
        if path not in source_links(record, text):
            return
        yield revision, record, text

        candidates = []
        for parent in git("rev-list", "--parents", "-1", revision).split()[1:]:
            document = parent_document(parent, revision, record)
            if document is None:
                continue
            previous = document_text(parent, document)
            if path in source_links(document, previous):
                candidates.append((parent, document, previous))
        if not candidates:
            return
        # Follow one coherent lineage, not interleaved patches from branches.
        # Prefer an inherited document; for a resolution, take the first
        # continuous parent in Git's parent order.
        revision, record, _ = next(
            (candidate for candidate in candidates if candidate[2] == text), candidates[0],
        )


def source_target(document, target):
    if target.startswith(("http://", "https://", "mailto:", "tel:", "#")):
        return None
    target = target.split("#", 1)[0].split("?", 1)[0].replace("%20", " ")
    if not target:
        return None
    path = target if target.startswith("/") else f"{posixpath.dirname(document)}/{target}"
    parts = []
    for part in path.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            if not parts:
                return None
            parts.pop()
        else:
            parts.append(part)
    return "/".join(parts) or None


def markdown_prose(text, *, keep_spans=False):
    """Mask code while preserving offsets and physical header line numbers."""
    lines = []
    fence = None
    indented = False
    blank = True
    for line in text.splitlines(keepends=True):
        content = line.rstrip("\r\n")
        code = False
        if fence is not None:
            if re.fullmatch(r" {0,3}" + re.escape(fence[0]) +
                            "{" + str(len(fence)) + r",}[ \t]*", content):
                fence = None
            code = True
        else:
            match = re.match(r" {0,3}(`{3,}|~{3,})(.*)$", content)
            if match and (match[1][0] == "~" or "`" not in match[2]):
                fence = match[1]
                code = True
            elif content.startswith(("    ", "\t")) and (blank or indented):
                indented = code = True
            elif content.strip():
                indented = False
        lines.append(re.sub(r"[^\r\n]", " ", line) if code else line)
        blank = not content.strip()
    text = "".join(lines)
    if keep_spans:
        return text

    pieces = []
    # Inline spans may cross a soft line break, but not a paragraph/code block.
    for paragraph in re.split(r"(\r?\n[ \t]*\r?\n)", text):
        runs = list(re.finditer(r"`+", paragraph))
        start = index = 0
        while index < len(runs):
            opening = runs[index]
            prefix = paragraph[:opening.start()]
            if (len(prefix) - len(prefix.rstrip("\\"))) % 2:
                index += 1
                continue
            closing = next((other for other in range(index + 1, len(runs))
                            if runs[other][0] == opening[0]), None)
            if closing is None:
                index += 1
                continue
            end = runs[closing].end()
            pieces.extend((paragraph[start:opening.start()],
                           re.sub(r"[^\r\n]", " ", paragraph[opening.start():end])))
            start = end
            index = closing + 1
        pieces.append(paragraph[start:])
    return "".join(pieces)


def markdown_links(text):
    text = markdown_prose(text)
    targets = re.findall(r"\]\(([^)\s]+)", text)
    targets += re.findall(r"^\[[^\]]+\]:\s+([^\s]+)", text, re.MULTILINE)
    return targets


def freshness_stamp(text):
    # Only the first real metadata line counts. Examples below a date-only
    # header cannot restore a migrated legacy stamp or override an invalid one.
    for original, prose in zip(text.splitlines()[:12], markdown_prose(text).splitlines()[:12]):
        if prose.startswith("> Last updated:"):
            return original
    return None


def source_links(document, text):
    return {source_target(document, target) for target in markdown_links(text)}


def source_exists(record, path, target):
    if source_target(record, target) != path:
        raise ValueError("cannot resolve current source-link target")
    introduction = None
    commit = None
    for revision, document, text in document_history(record, path):
        introduction = revision
        stamp = freshness_stamp(text)
        if stamp is None or "commit" not in stamp:
            continue
        match = re.fullmatch(
            r"> Last updated: [0-9]{4}-[0-9]{2}-[0-9]{2} (?:[^\w\s]+ )?commit `([0-9a-f]{7,40})`(?: .*)?",
            stamp,
        )
        if match is None:
            raise ValueError("cannot resolve historical commit from legacy stamp")
        try:
            commit = git("rev-parse", "--verify", f"{match[1]}^{{commit}}").strip()
        except subprocess.CalledProcessError as error:
            raise ValueError("cannot resolve historical commit from legacy stamp") from error
        break

    # Only a legacy stamp reached through a continuous semantic link takes
    # precedence over its introduction. Freshness dates never select commits.
    if commit is None:
        if introduction is None:
            raise ValueError("no committed source-link provenance; use an immutable source URL")
        commit = introduction

    result = subprocess.run(
        ["git", "cat-file", "-t", f"{commit}:{path}"],
        text=True, capture_output=True,
    )
    return result.returncode == 0 and result.stdout.strip() in ("blob", "tree")


if __name__ == "__main__":
    if len(sys.argv) == 3:
        mode, filename = sys.argv[1:]
        text = Path(filename).read_text(encoding="utf-8")
        if mode == "--links":
            for target in markdown_links(text):
                print(target)
        elif mode == "--check-stamp":
            stamp = freshness_stamp(text)
            sys.exit(0 if stamp and re.fullmatch(r"> Last updated: [0-9]{4}-[0-9]{2}-[0-9]{2}", stamp) else 1)
        elif mode == "--without-code-blocks":
            print(markdown_prose(text, keep_spans=True), end="")
        else:
            sys.exit(f"unknown extraction mode: {mode}")
        sys.exit(0)
    record, path, target = sys.argv[1:]
    try:
        sys.exit(0 if source_exists(record, path, target) else 1)
    except (subprocess.CalledProcessError, ValueError, StopIteration) as error:
        print(f"docs-check: {record}: {error}; inspect document history and fetch missing objects",
              file=sys.stderr)
        sys.exit(1)
