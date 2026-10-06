#!/bin/bash
# Stamp Markdown docs with the date the content was last updated or verified.
#
#   > Last updated: 2026-09-03
#
# The line is inserted directly under the H1 (or at the top when a file has no
# H1 in its first lines). Re-running replaces an existing stamp in place, so the
# script is idempotent. `scripts/docs-check.sh` fails any doc without a stamp.
#
# Usage:
#   scripts/docs-stamp.sh [--from-git] [FILE...]
#
#   (no files)   stamp every git-tracked Markdown file under docs/
#   --from-git   keep an existing stamp's date, or use the file's last commit
#                date (for historical records that must not claim a new date)
#
# Environment:
#   DOCS_STAMP_DATE    override the date (YYYY-MM-DD); default: today (UTC)
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

FROM_GIT=0
FILES=()
for arg in "$@"; do
    case "$arg" in
        --from-git) FROM_GIT=1 ;;
        -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) FILES+=("$arg") ;;
    esac
done

if [ ${#FILES[@]} -eq 0 ]; then
    while IFS= read -r f; do FILES+=("$f"); done < <(git ls-files -- 'docs/*.md' 'docs/**/*.md')
fi

TODAY=${DOCS_STAMP_DATE:-$(date -u +%Y-%m-%d)}
if [[ ! "$TODAY" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "docs-stamp: DOCS_STAMP_DATE must be YYYY-MM-DD" >&2
    exit 1
fi

stamp_one() {
    local file=$1 date=$2
    local line="> Last updated: ${date}"
    local tmp
    tmp=$(mktemp)
    if head -n 12 "$file" | grep -Eq '^> Last updated: [0-9]{4}-[0-9]{2}-[0-9]{2}'; then
        # Replace the existing stamp in place.
        awk -v stamp="$line" '
            !done && NR <= 12 && /^> Last updated: [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ {
                note = substr($0, 27)
                if (!sub(/^ *[^[:alnum:][:space:]]+ commit `[0-9a-f]+` */, "", note)) {
                    sub(/^ *commit `[0-9a-f]+` */, "", note)
                }
                sub(/^[[:space:]]+/, "", note)
                print stamp
                # Keep non-stamp annotations as body text, not metadata.
                if (note != "") { print ""; print note }
                done = 1; next
            }
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
        echo "stamped  $file  ($date)"
    else
        rm -f "$tmp"
    fi
}

for f in "${FILES[@]}"; do
    [ -f "$f" ] || { echo "docs-stamp: no such file: $f" >&2; exit 1; }
    if [ "$FROM_GIT" -eq 1 ]; then
        # Preserve a frozen record's date across stamp migrations and renames.
        date=$(sed -nE '1,12s/^> Last updated: ([0-9]{4}-[0-9]{2}-[0-9]{2}).*/\1/p' "$f" | head -n 1)
        if [ -z "$date" ]; then
            date=$(git log -1 --follow --diff-filter=AM --format='%as' -- "$f" || true)
        fi
        stamp_one "$f" "${date:-$TODAY}"
    else
        stamp_one "$f" "$TODAY"
    fi
done
