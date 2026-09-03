#!/bin/bash
# Stamp Markdown docs with a freshness line: when the doc was last updated and
# the repo commit its claims were verified against.
#
#   > Last updated: 2026-09-03 · commit `5d400cf75`
#
# The line is inserted directly under the H1 (or at the top when a file has no
# H1 in its first lines). Re-running replaces an existing stamp in place, so the
# script is idempotent. `scripts/docs-check.sh` fails any doc without a stamp.
#
# Usage:
#   scripts/docs-stamp.sh [--from-git] [FILE...]
#
#   (no files)   stamp every git-tracked Markdown file under docs/
#   --from-git   use each file's own last commit date + SHA instead of today +
#                HEAD (for historical records that must not claim a new date)
#
# Environment:
#   DOCS_STAMP_DATE    override the date (YYYY-MM-DD); default: today (UTC)
#   DOCS_STAMP_COMMIT  override the commit; default: `git rev-parse --short HEAD`
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

FROM_GIT=0
FILES=()
for arg in "$@"; do
    case "$arg" in
        --from-git) FROM_GIT=1 ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) FILES+=("$arg") ;;
    esac
done

if [ ${#FILES[@]} -eq 0 ]; then
    while IFS= read -r f; do FILES+=("$f"); done < <(git ls-files -- 'docs/*.md' 'docs/**/*.md')
fi

TODAY=${DOCS_STAMP_DATE:-$(date -u +%Y-%m-%d)}
HEAD_SHA=${DOCS_STAMP_COMMIT:-$(git rev-parse --short=9 HEAD)}

stamp_one() {
    local file=$1 date=$2 sha=$3
    local line="> Last updated: ${date} · commit \`${sha}\`"
    local tmp
    tmp=$(mktemp)
    if head -n 12 "$file" | grep -Eq '^> Last updated: [0-9]{4}-[0-9]{2}-[0-9]{2}'; then
        # Replace the existing stamp in place.
        awk -v stamp="$line" '
            !done && NR <= 12 && /^> Last updated: [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ { print stamp; done = 1; next }
            { print }
        ' "$file" > "$tmp"
    elif head -n 12 "$file" | grep -q '^# '; then
        # Insert under the first H1, keeping exactly one blank line on each side.
        awk -v stamp="$line" '
            !done && /^# / {
                print; print ""; print stamp
                if ((getline nextline) > 0) {
                    if (nextline != "") { print ""; print nextline } else { print "" }
                }
                done = 1; next
            }
            { print }
        ' "$file" > "$tmp"
    else
        { printf '%s\n\n' "$line"; cat "$file"; } > "$tmp"
    fi
    if ! cmp -s "$tmp" "$file"; then
        mv "$tmp" "$file"
        echo "stamped  $file  ($date $sha)"
    else
        rm -f "$tmp"
    fi
}

for f in "${FILES[@]}"; do
    [ -f "$f" ] || { echo "docs-stamp: no such file: $f" >&2; exit 1; }
    if [ "$FROM_GIT" -eq 1 ]; then
        meta=$(git log -1 --format='%as %h' -- "$f" || true)
        if [ -z "$meta" ]; then
            # Untracked file: fall back to today + HEAD.
            stamp_one "$f" "$TODAY" "$HEAD_SHA"
        else
            stamp_one "$f" "${meta% *}" "${meta#* }"
        fi
    else
        stamp_one "$f" "$TODAY" "$HEAD_SHA"
    fi
done
