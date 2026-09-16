#!/bin/bash
# Lint the docs tree. Fails (exit 1) on:
#   1. a doc without a freshness stamp in its first 12 lines
#        > Last updated: YYYY-MM-DD · commit `<sha>`
#      (add or refresh with scripts/docs-stamp.sh)
#   2. a relative Markdown link whose target file/directory does not exist
#      (frozen source links may instead exist at the document's stamped commit)
#   3. an inline-code citation of a repo path that does not exist, e.g.
#      `coordinator/api/server.go` or `provider-swift/Sources/ProviderCore/`
#      (line/symbol suffixes such as `file.go:123` or `file.go:Func` are
#      tolerated; globs and placeholders are skipped). Historical directories
#      (docs/reports/, docs/releases/, docs/design/) are exempt from this check
#      because they legitimately describe code that has since moved.
#   4. a docs/ Markdown file that no other doc links to (orphan) — every page
#      must be reachable from an index. Exempt: docs/README.md, docs/AGENTS.md.
#   5. a line naming SIP in README.md, docs/threat-model.yaml or
#      docs/provider/hardware-requirements.md that restates the immutability
#      guarantee but drops the "unpatched kernel" qualifier (the guarantee
#      holds only under Assumption 1 of papers/dginf-private-inference.tex;
#      see TB-003).
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

# Unlike the orphan check's normalizer, historical lookup must reject paths
# above the repository root and treat every component literally (no globs).
historical_repo_path() {
    local IFS='/' seg parts=() out=()
    read -r -a parts <<< "$1"
    for seg in "${parts[@]}"; do
        case "$seg" in
            ''|.) ;;
            ..)
                [ ${#out[@]} -gt 0 ] || return 1
                unset 'out[${#out[@]}-1]' ;;
            *) out+=("$seg") ;;
        esac
    done
    [ ${#out[@]} -gt 0 ] || return 1
    printf '%s\n' "${out[*]}"
}

historical_source_exists() {
    local f=$1 path record stamp commit kind
    record=$(historical_repo_path "$f") || return 1
    case "$record" in
        docs/reports/*|docs/releases/*|docs/design/*) ;;
        *) return 1 ;;
    esac
    path=$(historical_repo_path "$2") || return 1
    # Only repository source roots can use history. Documentation navigation,
    # including Markdown pages stored beside source, must keep working today.
    case "$path" in
        *.[mM][dD]|*.[mM][aA][rR][kK][dD][oO][wW][nN]) return 1 ;;
    esac
    case "$path" in
        coordinator/*|provider-swift/*|console-ui/*|admin-ui/*|landing/*|scripts/*|deploy/*|e2e/*|.github/*|.githooks/*|libs/*|fixtures/*) ;;
        *) return 1 ;;
    esac
    stamp=$(sed -nE '1,12s/^> Last updated: [0-9]{4}-[0-9]{2}-[0-9]{2} .*commit `([0-9a-f]{7,40})`.*/\1/p' "$f")
    if [ -z "$stamp" ]; then
        printf 'docs-check: %s: historical source requires a valid freshness stamp\n' "$f" >&2
        return 1
    fi
    if ! commit=$(git rev-parse --verify "${stamp}^{commit}" 2>/dev/null); then
        printf 'docs-check: %s: cannot resolve historical commit %s; verify the stamp and fetch complete Git history\n' "$f" "$stamp" >&2
        return 1
    fi
    kind=$(git cat-file -t "$commit:$path" 2>/dev/null) || return 1
    case "$kind" in blob|tree) return 0 ;; *) return 1 ;; esac
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
            http://*|https://*|mailto:*|\#*|tel:*) continue ;;
        esac
        target=${target%%#*}
        target=${target%%\?*}
        [ -z "$target" ] && continue
        # Percent-decode spaces only (the common case).
        target=${target//%20/ }
        case "$target" in
            /*) path=".${target}" ;;   # repo-absolute
            *)  path="$dir/$target" ;;
        esac
        if [ ! -e "$path" ]; then
            historical_source_exists "$f" "$path" && continue
            fail "$f: broken link -> $target"
        fi
    done < <(
        { grep -oE '\]\([^)[:space:]]+' "$f" | sed 's/^](//' ;
          grep -oE '^\[[^]]+\]:[[:space:]]+[^[:space:]]+' "$f" | sed -E 's/^\[[^]]+\]:[[:space:]]+//' ; } 2>/dev/null
    )
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
    for f in "${FILES[@]}" "${EXTRA_LINK_FILES[@]}"; do
        [ -f "$f" ] || continue
        dir=$(dirname "$f")
        grep -oE '\]\([^)[:space:]]+' "$f" 2>/dev/null | sed 's/^](//' |
        while IFS= read -r target; do
            case "$target" in http://*|https://*|mailto:*|\#*) continue ;; esac
            target=${target%%#*}; target=${target%%\?*}
            [ -z "$target" ] && continue
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
# 5. SIP immutability claims keep the kernel-integrity qualifier.
#    "Immutable for the process lifetime" holds only while the macOS kernel has
#    no unpatched vulnerability that bypasses SIP (Assumption 1,
#    papers/dginf-private-inference.tex). These three pages state that guarantee
#    to users, so a restatement that drops "unpatched" overstates it. Frozen
#    records (docs/reports/, docs/design/) keep their original wording.
# ---------------------------------------------------------------------------
CLAIM_FILES=(README.md docs/threat-model.yaml docs/provider/hardware-requirements.md)
CLAIM_RE='immutable for the process|reboot that kills|requires reboot|sound (given|because)'

# Lines that restate the guarantee. The claim phrases are generic, so one
# counts only when SIP is named on it or in the three lines above: the YAML
# folds its scalars, so a claim can start below the "SIP" that scopes it. That
# keeps the rule off unrelated reboot and soundness wording. The README's
# one-line summary of the residual threat model names no mechanism of its own,
# so match that sentence by name.
claim_lines() {
    local f=$1 n start
    while IFS=: read -r n _; do
        start=$((n > 3 ? n - 3 : 1))
        if sed -n "${start},${n}p" "$f" | grep -qi 'SIP'; then printf '%s\n' "$n"; fi
    done < <(grep -niE "$CLAIM_RE" "$f")
    if [ "$f" = README.md ]; then grep -ni 'engineered out' "$f" | cut -d: -f1; fi
}

for f in "${CLAIM_FILES[@]}"; do
    [ -f "$f" ] || continue
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        # The qualifier can land a line or two below the claim, for the same
        # folding reason. A qualifier pushed further away trips the rule
        # instead of slipping past it: the failure mode is a visible false
        # positive, not a miss.
        if ! sed -n "${n},$((n + 3))p" "$f" | grep -qi 'unpatched'; then
            fail "$f:$n: SIP immutability claim without the \"unpatched kernel\" qualifier (TB-003)"
        fi
    done < <(claim_lines "$f" | sort -un)
done

# The macOS row carries the patch-level guidance that makes the qualifier
# actionable for an operator.
if [ -f docs/provider/hardware-requirements.md ] &&
   ! grep '^| macOS |' docs/provider/hardware-requirements.md | grep -qi 'unpatched'; then
    fail "docs/provider/hardware-requirements.md: macOS row lost the security-update guidance (TB-003)"
fi

# ---------------------------------------------------------------------------
if [ "$ERRORS" -gt 0 ]; then
    printf 'docs-check: %d problem(s) in %d file(s)\n' "$ERRORS" "${#FILES[@]}" >&2
    exit 1
fi
printf 'docs-check: %d file(s) OK\n' "${#FILES[@]}"
