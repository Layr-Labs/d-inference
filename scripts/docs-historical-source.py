#!/usr/bin/env python3
"""Validate a frozen source target using committed document provenance."""

import posixpath
import re
import subprocess
import sys


def git(*arguments):
    return subprocess.run(
        ["git", "-c", "log.showSignature=false", *arguments],
        text=True, capture_output=True, check=True,
    ).stdout


def document_history(record):
    # --follow also follows copies. Stop there: a new record cannot inherit
    # another record's stamp or an earlier source-link introduction.
    tokens = iter(git("log", "--follow", "--format=%H", "--name-status", "-z",
                      "--", record).split("\0"))
    commit = None
    for token in tokens:
        token = token.strip()
        if re.fullmatch(r"[0-9a-f]{40,64}", token):
            commit = token
        elif re.fullmatch(r"[ACDMRTUXB][0-9]*", token):
            old = next(tokens)
            new = next(tokens) if token[0] in "RC" else old
            if commit is None or new != record:
                raise ValueError("cannot follow document history")
            yield commit, record
            if token[0] in "AC":
                return
            record = old


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


def source_links(document, text):
    lines = []
    fence = None
    for line in text.splitlines():
        if fence is not None:
            if re.fullmatch(r" {0,3}" + re.escape(fence[0]) +
                            "{" + str(len(fence)) + r",}[ \t]*", line):
                fence = None
            continue
        match = re.match(r" {0,3}(`{3,}|~{3,})(.*)$", line)
        if match and (match[1][0] == "~" or "`" not in match[2]):
            fence = match[1]
            continue
        lines.append(line)
    text = "\n".join(lines)
    targets = re.findall(r"\]\(([^)\s]+)", text)
    targets += re.findall(r"^\[[^\]]+\]:\s+([^\s]+)", text, re.MULTILINE)
    return {source_target(document, target) for target in targets}


def source_exists(record, path, target):
    if source_target(record, target) != path:
        raise ValueError("cannot resolve current source-link target")
    introduction = None
    commit = None
    for revision, document in document_history(record):
        text = git("show", f"{revision}:{document}")
        # A rename can change a relative destination even when link text is
        # identical. Stop before any legacy stamp outside this occurrence.
        if path not in source_links(document, text):
            break
        introduction = revision
        for line in text.splitlines()[:12]:
            if line.startswith("> Last updated:") and "commit" in line:
                match = re.fullmatch(
                    r"> Last updated: [0-9]{4}-[0-9]{2}-[0-9]{2} (?:[^\w\s]+ )?commit `([0-9a-f]{7,40})`(?: .*)?",
                    line,
                )
                if match is None:
                    raise ValueError("cannot resolve historical commit from legacy stamp")
                try:
                    commit = git("rev-parse", "--verify", f"{match[1]}^{{commit}}").strip()
                except subprocess.CalledProcessError as error:
                    raise ValueError("cannot resolve historical commit from legacy stamp") from error
                break
        else:
            continue
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
    record, path, target = sys.argv[1:]
    try:
        sys.exit(0 if source_exists(record, path, target) else 1)
    except (subprocess.CalledProcessError, ValueError, StopIteration) as error:
        print(f"docs-check: {record}: {error}; inspect document history and fetch missing objects",
              file=sys.stderr)
        sys.exit(1)
