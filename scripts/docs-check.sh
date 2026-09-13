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

# Parse every file once in one interpreter. Cache both views by array index so
# filenames with spaces need no encoding and both shell checks share the parse.
# Definitions are checked even when unused; only rendered links create edges.
LINK_FILES=("${FILES[@]}" "${EXTRA_LINK_FILES[@]}")
LINK_CACHE=$(mktemp -d) || exit 1
trap 'rm -rf "$LINK_CACHE"' EXIT
if ! python3 - "$LINK_CACHE" "${LINK_FILES[@]}" <<'PY_LINKS'
from pathlib import Path
import re
import sys

def label(value):
    return " ".join(value.split()).casefold()


# An escaped bracket is label text, including inside a clickable image. Keep
# backslashes out of the ordinary branch so backtracking cannot close early.
definition_pattern = re.compile(r"^ {0,3}\[((?:\\.|[^\]\\\n])+)\]:[ \t]*(?:<([^>\n]+)>|(\S+))")
# Labels may wrap within a paragraph, but not across blank lines or another
# block. Only ordered lists starting at 1 interrupt an existing paragraph.
block_start = r" {0,3}(?:#{1,6}(?:[ \t]|\n|$)|>|(?:[-+*]|1[.)])[ \t]+)"
# Setext underlines and thematic breaks occupy a whole line; marker prefixes
# followed by ordinary text remain part of the label.
setext_line = r" {0,3}(?:=+|-+)[ \t]*(?:\n|$)"
thematic_line = r" {0,3}(?:(?:\*[ \t]*){3,}|(?:-[ \t]*){3,}|(?:_[ \t]*){3,})(?:\n|$)"
marker_line = rf"(?:{setext_line}|{thematic_line})"
# CommonMark HTML block starts can interrupt a paragraph. Complete inline or
# custom tags cannot; treating every '<' as a boundary would lose real links.
html_block_names = (
    "address|article|aside|base|basefont|blockquote|body|caption|center|col|colgroup|dd|details|"
    "dialog|dir|div|dl|dt|fieldset|figcaption|figure|footer|form|frame|frameset|h[1-6]|head|header|"
    "hr|html|iframe|legend|li|link|main|menu|menuitem|nav|noframes|ol|optgroup|option|p|param|"
    "search|section|summary|table|tbody|td|tfoot|th|thead|title|tr|track|ul"
)
html_start = (
    r" {0,3}(?:<(?:!--|\?|![A-Za-z]|!\[CDATA\[)"
    r"|<(?i:pre|script|style|textarea)(?=[ \t\n>]|$)"
    rf"|</?(?i:{html_block_names})(?=[ \t\n>]|/>|$))"
)
# HTML tags are opaque inline tokens: their attributes are not Markdown, while
# text between inline tags still is. A standalone complete tag starts a block
# only outside a paragraph (the seventh CommonMark HTML block form).
html_attribute = r"[A-Za-z_:][A-Za-z0-9_.:-]*(?:[ \t\n]*=[ \t\n]*(?:\"[^\"]*\"|'[^']*'|[^ \t\n\"'=<>`]+))?"
html_tag = (
    rf"(?:<[A-Za-z][A-Za-z0-9-]*(?:[ \t\n]+{html_attribute})*[ \t\n]*/?>"
    r"|</[A-Za-z][A-Za-z0-9-]*[ \t\n]*>)"
)
html_inline = re.compile(
    rf"(?:<!--(?:-?>|.*?-->)|<\?.*?\?>|<!\[CDATA\[.*?\]\]>|<![A-Za-z][^>]*>|{html_tag})",
    re.DOTALL,
)
html_until_blank = re.compile(r"^$")
html_block_markers = (
    (r" {0,3}<(?i:pre|script|style|textarea)(?=[ \t>]|$)", r"</(?i:pre|script|style|textarea)>"),
    (r" {0,3}<!--", r"-->|^ {0,3}<!---?>"),
    (r" {0,3}<\?", r"\?>"),
    (r" {0,3}<![A-Za-z]", r">"),
    (r" {0,3}<!\[CDATA\[", r"\]\]>"),
)


def html_block_end(text, paragraph_open):
    for start, end in html_block_markers:
        if re.match(start, text):
            return re.compile(end)
    if re.match(rf" {{0,3}}</?(?i:{html_block_names})(?=[ \t>]|/>|$)", text) or (
        not paragraph_open and re.fullmatch(rf" {{0,3}}{html_tag}[ \t]*", text)
    ):
        return html_until_blank
    return None


def inline_literal_end(text, offset):
    """Skip one code/HTML token without changing bytes in surrounding labels."""
    unmatched_end = None
    if text[offset] == "`":
        opener = re.match(r"`+", text[offset:])[0]
        # An unmatched run is literal as a whole. Retrying at its second tick
        # could invent a shorter code span and hide a real link.
        unmatched_end = offset + len(opener)
        closing = re.search(rf"(?<!`){opener}(?!`)", text[offset + len(opener):])
        end = offset + len(opener) + closing.end() if closing else None
    elif text[offset] == "<":
        match = html_inline.match(text, offset)
        end = match.end() if match else None
    else:
        return None
    if end is not None and not re.search(
        rf"\n(?=[ \t]*\n|{block_start}|{marker_line}|{html_start})", text[offset:end]
    ):
        return end
    return unmatched_end


def collect_definitions(body):
    # Defer collection until inline literals are known. A definition-shaped
    # line inside a multiline HTML comment is not a reference definition.
    text = "\n".join(body)
    definitions, targets = {}, []
    cursor, offset = 0, 0
    for index, line in enumerate(body):
        definition = definition_pattern.match(line)
        if definition:
            while cursor < offset:
                if text[cursor] == "\\":
                    cursor += 2
                else:
                    cursor = inline_literal_end(text, cursor) or cursor + 1
            if cursor <= offset:
                target = definition[2] or definition[3]
                definitions.setdefault(label(definition[1]), target)
                targets.append(target)
                body[index] = None
                cursor = offset + len(line) + 1
        offset += len(line) + 1
    body[:] = [line for line in body if line is not None]
    return definitions, targets


soft_break = rf"\n(?![ \t]*\n|{block_start}|{marker_line}|{html_start})"
soft_break_pattern = re.compile(soft_break)
# Visible labels balance arbitrary bracket depth; reference identifiers only
# permit escaped brackets. Keep destination matching separate from that stack.
reference_unit = rf"(?:\\.|[^\[\]\\\n]|{soft_break})"
reference_suffix = re.compile(rf"\[(?P<reference>{reference_unit}*)\]")
inline_destination = re.compile(r"\(\s*(?:<(?P<angle>[^>\n]*)>|(?P<bare>[^\s)]*))")
link_space = re.compile(r"\s*")


def inline_link(text, offset):
    destination = inline_destination.match(text, offset)
    if destination is None:
        return None
    end = destination.end()
    spaced = link_space.match(text, end).end()
    marker = text[spaced:spaced + 1]
    if spaced > end and marker in ('"', "'", "("):
        # A quoted title is one opaque token. Its parentheses and brackets
        # cannot end the link or become independent navigation.
        delimiter = ")" if marker == "(" else marker
        end = spaced + 1
        while end < len(text):
            if text[end] == "\\":
                end += 2
            elif text[end] == delimiter:
                end = link_space.match(text, end + 1).end()
                break
            else:
                end += 1
        else:
            return None
    else:
        end = spaced
    if text[end:end + 1] != ")":
        return None
    for newline in re.finditer("\n", text[offset:end + 1]):
        if not soft_break_pattern.match(text, offset + newline.start()):
            return None
    target = destination["angle"] if destination["angle"] is not None else destination["bare"]
    return target, end + 1


def rendered_targets(text, definitions):
    openers, targets = [], []
    offset = 0
    while offset < len(text):
        char = text[offset]
        if char == "\\":
            # Pairs are literal; an unmatched slash escapes the next marker.
            offset += 1 if text[offset + 1:offset + 2] == "\n" else 2
            continue
        literal_end = inline_literal_end(text, offset)
        if literal_end is not None:
            offset = literal_end
            continue
        if char == "\n" and not soft_break_pattern.match(text, offset):
            openers.clear()
        image = text.startswith("![", offset)
        if image or char == "[":
            offset += 2 if image else 1
            openers.append({"start": offset, "image": image, "active": True,
                            "result_start": len(targets)})
            continue
        if char != "]" or not openers:
            offset += 1
            continue
        opener = openers.pop()
        visible_label = text[opener["start"]:offset]
        offset += 1
        if not opener["active"]:
            continue
        inline = inline_link(text, offset)
        reference = reference_suffix.match(text, offset) if inline is None else None
        finish = offset
        if inline is not None:
            target, finish = inline
        elif reference:
            target = definitions.get(label(reference["reference"] or visible_label))
            finish = reference.end()
        elif text[offset:offset + 1] == "[":
            # An invalid explicit reference suppresses shortcut fallback.
            target = None
        else:
            target = definitions.get(label(visible_label))
        if target is None:
            continue
        offset = finish
        if opener["image"]:
            # Image alt text may contain link syntax, but those inner targets
            # are rendered as alt text, not independent links or images.
            del targets[opener["result_start"]:]
        else:
            # Links cannot contain links. An inner resolved link takes
            # precedence over each earlier link opener, including across alt.
            for earlier in openers:
                if not earlier["image"]:
                    earlier["active"] = False
        targets.append((target, not opener["image"]))
    return targets


def parse(source):
    body, navigation = [], []
    fence = None
    fence_containers = []
    fence_parent = None
    html_end, html_depth, html_indent = None, 0, 0
    paragraph_open, quote_depth, list_indents = False, 0, []
    empty_item = False
    list_item = re.compile(r"^ {0,3}(?P<marker>[-+*]|[0-9]{1,9}[.)])(?P<padding> +|$)")
    for line in source.read_text().splitlines():
        content = line.expandtabs(4)
        if fence is not None:
            # Consume only the containers that opened this fence. Additional
            # quote/list-looking text inside the code stays literal.
            fenced_content = content
            closed = False
            for container in fence_containers:
                if container is None:
                    quote = re.match(r"^ {0,3}> ?", fenced_content)
                    if not quote:
                        break
                    fenced_content = fenced_content[quote.end():]
                elif fenced_content.strip():
                    if len(fenced_content) - len(fenced_content.lstrip(" ")) < container:
                        break
                    fenced_content = fenced_content[container:]
            else:
                marker = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", fenced_content)
                if not (marker and marker[1][0] == fence[0] and len(marker[1]) >= len(fence) and not marker[2].strip()):
                    continue
                closed = True
            # A fence cannot outlive its list item or quote. Reprocess this
            # line normally when its container prefix is no longer present.
            fence = None
            if fence_parent is not None:
                quote_depth, list_indents = fence_parent
            if closed:
                continue
        # Indented code starts outside a paragraph. Measure its four columns
        # from the list/quote content, so ordinary nested links stay visible.
        quote = re.match(r"^(?: {0,3}> ?)+", content)
        depth = quote[0].count(">") if quote else 0
        quote_containers = [None] * depth
        quote_parent = None
        if depth > quote_depth and list_indents:
            # A quote introduced on an indented list continuation still
            # belongs to that list, even though the quote prefix matches first.
            parent_content = content
            for _ in range(quote_depth):
                parent_quote = re.match(r"^ {0,3}> ?", parent_content)
                parent_content = parent_content[parent_quote.end():]
            list_indent = list_indents[-1]
            if len(parent_content) - len(parent_content.lstrip(" ")) >= list_indent:
                quote_containers = [None] * quote_depth + [list_indent] + [None] * (depth - quote_depth)
                quote_parent = (quote_depth, list_indents.copy())
        if depth != quote_depth:
            list_indents = []
            empty_item = False
            if depth > quote_depth:
                paragraph_open = False
        quote_depth = depth
        if quote:
            content = content[quote.end():]
        if html_end is not None and depth < html_depth:
            html_end = None
        if not content.strip():
            # A blank line closes an otherwise empty list item.
            if empty_item and list_indents:
                list_indents.pop()
            empty_item = False
            body.append("")
            paragraph_open = False
            if html_end is html_until_blank:
                html_end = None
            continue
        indent = len(content) - len(content.lstrip(" "))
        if html_end is not None:
            if indent >= html_indent:
                # HTML cannot acquire Markdown child blocks, definitions or
                # fences. End only at its terminator or its container boundary.
                if html_end.search(content[html_indent:]):
                    html_end = None
                body.append("")
                paragraph_open = False
                continue
            html_end = None
        was_in_list = bool(list_indents)
        while list_indents and indent < list_indents[-1]:
            if paragraph_open and not (
                list_item.match(content) or definition_pattern.match(content)
                or re.match(rf"(?:{block_start}|{marker_line}|{html_start})", content)
            ):
                break  # A lazy paragraph continuation need not repeat indentation.
            list_indents.pop()
        base = list_indents[-1] if list_indents and indent >= list_indents[-1] else 0
        relative = content[base:]
        empty_item = False
        while (item := list_item.match(relative)) and not (
            re.match(thematic_line, relative) or paragraph_open and re.match(setext_line, relative)
        ):
            if paragraph_open and not was_in_list and (
                item["marker"][0].isdigit() and item["marker"] not in ("1.", "1)")
                or not relative[item.end():].strip()
            ):
                break
            padding = len(item["padding"])
            base += item.start("padding") + (padding if 1 <= padding <= 4 else 1)
            list_indents.append(base)
            relative = content[base:]
            paragraph_open = False
            empty_item = not relative.strip()
        if not paragraph_open and len(relative) - len(relative.lstrip(" ")) >= 4:
            body.append("")
            continue
        # Lists may themselves contain quotes (and further lists). Record
        # those prefixes without treating code inside them as new containers.
        fenced_content, nested_containers = relative, []
        while (quote := re.match(r"^ {0,3}> ?", fenced_content)):
            nested_containers.append(None)
            fenced_content = fenced_content[quote.end():]
            while (item := list_item.match(fenced_content)):
                padding = len(item["padding"])
                width = item.start("padding") + (padding if 1 <= padding <= 4 else 1)
                nested_containers.append(width)
                fenced_content = fenced_content[width:]
        marker = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", fenced_content)
        # Backtick fence info strings cannot contain backticks, even escaped
        # ones. An invalid opener remains ordinary Markdown.
        if marker and (marker[1][0] != "`" or "`" not in marker[2]):
            fence = marker[1]
            # None records a quote prefix; an integer records list indentation.
            fence_containers = quote_containers + ([base] if base else []) + nested_containers
            # Retain the surrounding list when a later fence starts in the
            # same indented quote after this fence closes.
            fence_parent = quote_parent
            body.append("")
            paragraph_open = False
            empty_item = False
            while list_indents and base < list_indents[-1]:
                list_indents.pop()
            continue
        html_end = html_block_end(relative, paragraph_open)
        if html_end is not None:
            html_depth, html_indent = depth, base
            if html_end.search(relative):
                html_end = None
            body.append("")
            paragraph_open = False
            continue
        body.append(line)
        if not definition_pattern.match(line):
            heading = re.match(r"^ {0,3}#{1,6}(?:[ \t]|$)", relative)
            ends_paragraph = (heading or re.match(thematic_line, relative)
                              or paragraph_open and re.match(setext_line, relative)
                              or re.match(html_start, relative))
            paragraph_open = bool(relative.strip()) and not ends_paragraph
            if heading:
                # An ATX heading ends on its own line even without a blank.
                body.append("")

    # Inline code and HTML are skipped during scanning, preserving their raw
    # bytes inside an enclosing label instead of joining unrelated syntax.
    definitions, all_targets = collect_definitions(body)
    text = "\n".join(body)
    for target, navigates in rendered_targets(text, definitions):
        all_targets.append(target)
        if navigates:
            navigation.append(target)
    return all_targets, navigation


cache = Path(sys.argv[1])
for index, filename in enumerate(sys.argv[2:]):
    source = Path(filename)
    if source.is_file():
        all_targets, navigation = parse(source)
        for mode, targets in (("all", all_targets), ("navigation", navigation)):
            (cache / f"{index}.{mode}").write_text("".join(target + "\n" for target in targets))
PY_LINKS
then
    fail "unable to parse Markdown links"
    exit 1
fi

relative_targets() {
    local target
    while IFS= read -r target; do
        case "$target" in http://*|https://*|mailto:*|\#*|tel:*) continue ;; esac
        target=${target%%#*}
        target=${target%%\?*}
        [ -n "$target" ] && printf '%s\n' "${target//%20/ }"
    done < "$LINK_CACHE/$1.${2:-all}"
}

# ---------------------------------------------------------------------------
# 2. Relative links
# ---------------------------------------------------------------------------
check_links() {
    local f=$1 index=$2 dir target path
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
    done < <(relative_targets "$index")
}

for index in "${!LINK_FILES[@]}"; do
    f=${LINK_FILES[$index]}
    [ -f "$f" ] || continue
    check_links "$f" "$index"
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
    LINKED="$LINK_CACHE/linked"
    for index in "${!LINK_FILES[@]}"; do
        f=${LINK_FILES[$index]}
        [ -f "$f" ] || continue
        dir=$(dirname "$f")
        relative_targets "$index" navigation |
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
fi

# ---------------------------------------------------------------------------
if [ "$ERRORS" -gt 0 ]; then
    printf 'docs-check: %d problem(s) in %d file(s)\n' "$ERRORS" "${#FILES[@]}" >&2
    exit 1
fi
printf 'docs-check: %d file(s) OK\n' "${#FILES[@]}"
