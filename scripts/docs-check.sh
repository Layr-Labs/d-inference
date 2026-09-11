#!/bin/bash
# Lint the docs tree. Fails (exit 1) on:
#   1. a doc without a freshness stamp in its first 12 lines
#        > Last updated: YYYY-MM-DD · commit `<sha>`
#      (add or refresh with scripts/docs-stamp.sh)
#   2. a relative Markdown link whose target file/directory does not exist
#   3. an inline-code citation of a repo path that does not exist, e.g.
#      `coordinator/api/server.go` or `provider-swift/Sources/ProviderCore/`
#      (line/symbol suffixes such as `file.go:123` or `file.go:Func` are
#      tolerated; globs and placeholders are skipped). Historical directories
#      (docs/reports/, docs/releases/, docs/design/) are exempt from this check
#      because they legitimately describe code that has since moved.
#   4. a docs/ Markdown file that no other doc links to (orphan) — every page
#      must be reachable from an index. Exempt: docs/README.md, docs/AGENTS.md.
#
# Usage:
#   scripts/docs-check.sh            # check git-tracked docs (what CI runs)
#   scripts/docs-check.sh --all      # also include untracked docs
#   scripts/docs-check.sh FILE...    # check only the given files (no orphan check)
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

INCLUDE_UNTRACKED=0
FILES=()
for arg in "$@"; do
    case "$arg" in
        --all) INCLUDE_UNTRACKED=1 ;;
        -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) FILES+=("$arg") ;;
    esac
done

ORPHAN_CHECK=1
if [ ${#FILES[@]} -eq 0 ]; then
    while IFS= read -r f; do FILES+=("$f"); done < <(git ls-files -- 'docs/*.md' 'docs/**/*.md')
    if [ "$INCLUDE_UNTRACKED" -eq 1 ]; then
        while IFS= read -r f; do FILES+=("$f"); done < <(git ls-files --others --exclude-standard -- 'docs/*.md' 'docs/**/*.md')
    fi
else
    ORPHAN_CHECK=0
fi

# Files we lint for links but never for stamps/orphans.
EXTRA_LINK_FILES=(README.md CONTRIBUTING.md AGENTS.md)

ERRORS=0
fail() { printf 'docs-check: %s\n' "$*" >&2; ERRORS=$((ERRORS + 1)); }

# ---------------------------------------------------------------------------
# 1. Freshness stamp
# ---------------------------------------------------------------------------
for f in "${FILES[@]}"; do
    case "$f" in docs/.private/*) continue ;; esac
    if ! head -n 12 "$f" | grep -Eq '^> Last updated: [0-9]{4}-[0-9]{2}-[0-9]{2} .*commit `[0-9a-f]{7,40}`'; then
        fail "$f: missing freshness stamp (run scripts/docs-stamp.sh \"$f\")"
    fi
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# Print Markdown text with fenced code blocks removed (so example output is not
# treated as citations) — inline code spans are kept.
strip_fences() {
    awk 'BEGIN { infence = 0 }
         /^[[:space:]]*(```|~~~)/ { infence = !infence; next }
         !infence { print }' "$1"
}

# Collapse `.` and `..` segments of a repo-relative path without touching the
# filesystem (pure bash; avoids a subshell per link).
normpath() {
    local IFS='/' seg out=()
    for seg in $1; do
        case "$seg" in
            ''|.) ;;
            ..) [ ${#out[@]} -gt 0 ] && unset 'out[${#out[@]}-1]' ;;
            *)  out+=("$seg") ;;
        esac
    done
    printf '%s\n' "${out[*]}"
}

# One parser feeds existence checks and the navigation graph. Definitions are
# checked even when unused, but only rendered link uses create navigation edges.
link_targets() {
    python3 - "$1" "${2:-all}" <<'PY_LINKS'
from pathlib import Path
import re
import sys

source, mode = sys.argv[1:]
lines = []
fence = None
for line in Path(source).read_text().splitlines():
    marker = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", line)
    if fence is not None:
        if marker and marker[1][0] == fence[0] and len(marker[1]) >= len(fence) and not marker[2].strip():
            fence = None
        continue
    if marker:
        fence = marker[1]
        continue
    lines.append(line)


def label(value):
    return " ".join(value.split()).casefold()


definitions = {}
body = []
for line in lines:
    definition = re.match(r"^ {0,3}\[([^]\n]+)\]:[ \t]*(?:<([^>\n]+)>|(\S+))", line)
    if definition:
        target = definition[2] or definition[3]
        definitions.setdefault(label(definition[1]), target)
        if mode == "all":
            print(target)
    else:
        body.append(line)

text = "\n".join(body)
# Backtick spans contain literal examples, not rendered links.
text = re.sub(r"(?<!`)(`+)(?!`).*?\1(?!`)", "", text, flags=re.DOTALL)
links = re.compile(
    r"(?<!\\)(?P<image>!)?\[(?P<label>[^]\n]*)\]"
    r"(?:\(\s*(?:<(?P<angle>[^>\n]+)>|(?P<bare>[^\s)]+))[^)]*\)|\[(?P<reference>[^]\n]*)\])?"
)
for match in links.finditer(text):
    # Image targets must exist, but an image alone is not clickable navigation.
    if mode != "all" and match["image"]:
        continue
    if match["angle"] is not None or match["bare"] is not None:
        print(match["angle"] or match["bare"])
    else:
        # Full [text][id], collapsed [id][], and shortcut [id] references.
        reference = match["reference"] or match["label"]
        target = definitions.get(label(reference))
        if target is not None:
            print(target)
PY_LINKS
}

relative_targets() {
    local target
    while IFS= read -r target; do
        case "$target" in http://*|https://*|mailto:*|\#*|tel:*) continue ;; esac
        target=${target%%#*}
        target=${target%%\?*}
        [ -n "$target" ] && printf '%s\n' "${target//%20/ }"
    done < <(link_targets "$1" "${2:-all}")
}

# ---------------------------------------------------------------------------
# 2. Relative links
# ---------------------------------------------------------------------------
check_links() {
    local f=$1 dir target path
    dir=$(dirname "$f")
    # Inline links [text](target) and reference definitions [id]: target.
    # The loop reads from process substitution (not a pipeline) so that `fail`
    # increments ERRORS in this shell rather than in a throwaway subshell.
    while IFS= read -r target; do
        case "$target" in
            /*) path=".${target}" ;;   # repo-absolute
            *)  path="$dir/$target" ;;
        esac
        if [ ! -e "$path" ]; then
            fail "$f: broken link -> $target"
        fi
    done < <(relative_targets "$f")
}

for f in "${FILES[@]}" "${EXTRA_LINK_FILES[@]}"; do
    [ -f "$f" ] || continue
    check_links "$f"
done

# ---------------------------------------------------------------------------
# 3. Code-path citations in inline code
# ---------------------------------------------------------------------------
CITE_ROOTS='coordinator|provider-swift|console-ui|admin-ui|landing|scripts|deploy|e2e|docs|\.github|\.githooks|libs|fixtures'

check_citations() {
    local f=$1 cite path sub
    # Process substitution, not a pipeline: see check_links.
    while IFS= read -r cite; do
        # Skip globs, placeholders, ranges, and prose fragments.
        case "$cite" in
            *'*'*|*'{'*|*'<'*|*'$'*|*'…'*|*'...'*|*'['*|*'|'*) continue ;;
        esac
        path=$cite
        # Drop `:line`, `:line-line`, `:Symbol`, and trailing punctuation.
        path=${path%%:*}
        path=${path%%,}
        path=${path%%.}
        path=${path%%\)}
        [ -z "$path" ] && continue
        # Citations into a submodule that is not initialised in this checkout
        # (empty libs/<name>/ — e.g. CI without `submodules: recursive`, or a
        # fresh worktree) cannot be verified here; skip rather than fail.
        case "$path" in
            libs/*/*)
                sub=${path#libs/}; sub="libs/${sub%%/*}"
                if [ -d "$sub" ] && [ -z "$(ls -A "$sub" 2>/dev/null)" ]; then continue; fi ;;
        esac
        if [ ! -e "$path" ]; then
            fail "$f: cites missing path \`$cite\`"
        fi
    done < <(
        strip_fences "$f" |
        grep -oE '`('"$CITE_ROOTS"')/[^` ]*`' 2>/dev/null |
        tr -d '`' |
        sort -u
    )
}

for f in "${FILES[@]}"; do
    case "$f" in
        docs/reports/*|docs/releases/*|docs/design/*|docs/.private/*) continue ;;
    esac
    check_citations "$f"
done

# ---------------------------------------------------------------------------
# 4. Orphans — every docs page must be linked from somewhere in docs/ or the
#    root README/CONTRIBUTING/AGENTS.
# ---------------------------------------------------------------------------
if [ "$ORPHAN_CHECK" -eq 1 ]; then
    # Build the set of link targets, normalised to repo-relative paths.
    LINKED=$(mktemp)
    trap 'rm -f "$LINKED"' EXIT
    for f in "${FILES[@]}" "${EXTRA_LINK_FILES[@]}"; do
        [ -f "$f" ] || continue
        dir=$(dirname "$f")
        relative_targets "$f" navigation |
        while IFS= read -r target; do
            case "$target" in
                /*) path=".${target}" ;;
                *)  path="$dir/$target" ;;
            esac
            [ -e "$path" ] || continue
            normpath "$path"
        done
    done | sort -u > "$LINKED"

    for f in "${FILES[@]}"; do
        case "$f" in
            docs/README.md|docs/AGENTS.md|docs/.private/*) continue ;;
        esac
        if ! grep -qxF "$f" "$LINKED"; then
            fail "$f: orphan (no doc links to it — add it to the nearest README index)"
        fi
    done
    rm -f "$LINKED"
fi

# ---------------------------------------------------------------------------
if [ "$ERRORS" -gt 0 ]; then
    printf 'docs-check: %d problem(s) in %d file(s)\n' "$ERRORS" "${#FILES[@]}" >&2
    exit 1
fi
printf 'docs-check: %d file(s) OK\n' "${#FILES[@]}"
