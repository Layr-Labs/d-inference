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
#   4. a docs/ page unreachable from docs/README.md, docs/AGENTS.md or root docs.
#      docs/.private/* pages are exempt; self-links and disconnected cycles fail.
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
from string import punctuation
import re
import sys

def label(value):
    return " ".join(value.split()).casefold()


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
    r" {0,3}(?:<(?:!--|\?|![A-Z]|!\[CDATA\[)"
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
# GFM inline declarations require an uppercase name followed by whitespace;
# its block declaration rule only requires an uppercase first letter.
html_inline = re.compile(
    rf"(?:<!--(?:-?>|.*?-->)|<\?.*?\?>|<!\[CDATA\[.*?\]\]>|<![A-Z]+[ \t\r\n\f\v][^>]*>|{html_tag})",
    re.DOTALL,
)
html_until_blank = re.compile(r"^$")
html_block_markers = (
    (r" {0,3}<(?i:pre|script|style|textarea)(?=[ \t>]|$)", r"</(?i:pre|script|style|textarea)>"),
    (r" {0,3}<!--", r"-->|^ {0,3}<!---?>"),
    (r" {0,3}<\?", r"\?>"),
    (r" {0,3}<![A-Z]", r">"),
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


def definition_lines(lines, start, first, containers):
    """Project continuation text from the definition's existing containers."""
    yield start, first
    for index in range(start + 1, len(lines)):
        content = lines[index].expandtabs(4)
        for container in containers:
            if container is None:
                quote = re.match(r"^ {0,3}> ?", content)
                if not quote:
                    break
                content = content[quote.end():]
            elif len(content) - len(content.lstrip(" ")) >= container:
                content = content[container:]
            else:
                break
        # Missing container prefixes can be lazy paragraph continuations, but
        # blank lines and new blocks cannot be part of a label or title.
        if not content.strip() or re.match(
            rf"(?:{block_start}|{marker_line}|{html_start}| {{0,3}}(?:`{{3,}}(?![^\n]*`)|~{{3,}}))", content
        ):
            return
        yield index, content


definition_space = re.compile(r"[ \t]*")


def read_definition(lines, start, first, containers):
    """Consume a complete paragraph-leading definition, including its title."""
    opener = re.match(r"^ {0,3}\[", first)
    if opener is None:
        return None
    continuation = iter(definition_lines(lines, start, first, containers))
    line_index, text = next(continuation)

    def extend():
        nonlocal line_index, text
        following = next(continuation, None)
        if following is None:
            return False
        line_index, line = following
        text += "\n" + line
        return True

    offset, label_start = opener.end(), opener.end()
    while True:
        if offset >= len(text):
            if not extend():
                return None
        char = text[offset]
        if offset - label_start > 999 or char == "[":
            return None
        if char == "]":
            break
        offset += 2 if char == "\\" and text[offset + 1:offset + 2] in ("[", "]", "\\") else 1
    identifier = label(text[label_start:offset])
    if not identifier or text[offset + 1:offset + 2] != ":":
        return None
    offset += 2
    offset = definition_space.match(text, offset).end()
    if offset == len(text):
        if not extend():
            return None
        offset = definition_space.match(text, offset + 1).end()
    destination = link_destination(text, offset)
    if destination is None or not destination[0] and text[offset:offset + 1] != "<":
        return None
    target, end = destination
    spaced = definition_space.match(text, end).end()
    # A failed title on a later line leaves a valid destination-only
    # definition. A malformed suffix on the destination line invalidates it.
    destination_only = (identifier, target, line_index) if spaced == len(text) else None
    if spaced == len(text):
        if not extend():
            return destination_only
        spaced = definition_space.match(text, spaced + 1).end()
    marker = text[spaced:spaced + 1]
    if spaced == end or marker not in ('"', "'", "("):
        return destination_only
    delimiter = ")" if marker == "(" else marker
    offset = spaced + 1
    while True:
        if offset >= len(text):
            if not extend():
                return destination_only
        char = text[offset]
        if char == delimiter:
            trailing = text[offset + 1:]
            return (identifier, target, line_index) if not trailing.strip(" \t") else destination_only
        offset += 2 if char == "\\" and text[offset + 1:offset + 2] in (delimiter, "\\") else 1


soft_break = rf"\n(?![ \t]*\n|{block_start}|{marker_line}|{html_start})"
soft_break_pattern = re.compile(soft_break)
# Visible labels balance arbitrary bracket depth; reference identifiers only
# permit escaped brackets. Keep destination matching separate from that stack.
reference_unit = rf"(?:\\.|[^\[\]\\\n]|{soft_break})"
reference_suffix = re.compile(rf"\[(?P<reference>{reference_unit}*)\]")
link_space = re.compile(r"\s*")


def link_destination(text, offset, max_depth=None):
    """Read an angle-wrapped or balanced bare destination and its end offset."""
    enclosed = text[offset:offset + 1] == "<"
    end, depth, target = offset + int(enclosed), 0, []
    while end < len(text):
        char = text[end]
        if char == "\\" and end + 1 < len(text) and text[end + 1] in punctuation:
            target.append(text[end + 1])
            end += 2
            continue
        if enclosed:
            if char == ">":
                return "".join(target), end + 1
            if char in "<\r\n":
                return None
        else:
            if char in " \t\r\n" or char == ")" and depth == 0:
                break
            if ord(char) < 32 or ord(char) == 127:
                return None
            if char == "(":
                depth += 1
                if max_depth is not None and depth > max_depth:
                    return None
            elif char == ")":
                depth -= 1
        target.append(char)
        end += 1
    if enclosed or depth:
        return None
    return "".join(target), end


def inline_link(text, offset):
    if text[offset:offset + 1] != "(":
        return None
    # The renderer limits bare inline destinations to 32 nested pairs;
    # reference, angle-wrapped and escaped destinations have no such limit.
    destination = link_destination(text, link_space.match(text, offset + 1).end(), max_depth=32)
    if destination is None:
        return None
    target, end = destination
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


def project_containers(content, containers):
    """Consume existing list/quote prefixes without inventing child blocks."""
    for index, container in enumerate(containers):
        if container is None:
            quote = re.match(r"^ {0,3}> ?", content)
            if not quote:
                return content, index
            content = content[quote.end():]
        elif content.strip():
            if len(content) - len(content.lstrip(" ")) < container:
                return content, index
            content = content[container:]
    return content, len(containers)


def parse(source):
    body, navigation, all_targets = [], [], []
    definitions = {}
    containers = []
    paragraph_open, empty_item = False, False
    literal = None
    list_item = re.compile(r"^ {0,3}(?P<marker>[-+*]|[0-9]{1,9}[.)])(?P<padding> +|$)")
    lines = source.read_text().splitlines()
    skip_through = -1
    for line_index, line in enumerate(lines):
        if line_index <= skip_through:
            continue
        expanded_line = line.expandtabs(4)
        content = expanded_line
        if literal is not None:
            kind, ending, owners = literal
            projected, matched = project_containers(content, owners)
            if matched == len(owners):
                if kind == "code":
                    if not projected.strip() or len(projected) - len(projected.lstrip(" ")) >= 4:
                        continue
                elif kind == "html":
                    if ending.search(projected) or ending is html_until_blank and not projected.strip():
                        literal = None
                    continue
                else:
                    marker = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", projected)
                    if marker and marker[1][0] == ending[0] and len(marker[1]) >= len(ending) and not marker[2].strip():
                        literal = None
                    continue
            # A literal block cannot outlive its opening containers. A code
            # block also ends before its first non-indented content line.
            literal = None

        content, matched = project_containers(content, containers)
        if matched < len(containers):
            # Only an existing paragraph can omit its container prefixes.
            # A sibling list item or another block starts a new paragraph.
            sibling_item = containers[matched] is not None and list_item.match(content)
            interrupts = re.match(
                rf"(?:{block_start}|{marker_line}|{html_start}| {{0,3}}(?:`{{3,}}(?![^\n]*`)|~{{3,}}))", content
            )
            if not (paragraph_open and content.strip() and not sibling_item and not interrupts):
                containers = containers[:matched]
                paragraph_open, empty_item = False, False
                body.append("")
        if not content.strip():
            if empty_item and containers and containers[-1] is not None:
                containers.pop()
            paragraph_open, empty_item = False, False
            body.append("")
            continue

        # Project every new list and quote before classifying its leaf. The
        # same ordered chain is retained for continuation and exit handling.
        empty_item = False
        while True:
            quote = re.match(r"^ {0,3}> ?", content)
            if quote:
                containers.append(None)
                content = content[quote.end():]
                paragraph_open = False
                body.append("")
                continue
            item = list_item.match(content)
            if item is None or re.match(thematic_line, content) or paragraph_open and re.match(setext_line, content):
                break
            if paragraph_open and (
                item["marker"][0].isdigit() and item["marker"] not in ("1.", "1)")
                or not content[item.end():].strip()
            ):
                break
            padding = len(item["padding"])
            width = item.start("padding") + (padding if 1 <= padding <= 4 else 1)
            containers.append(width)
            content = content[width:]
            paragraph_open = False
            empty_item = not content.strip()
            body.append("")
        if not content.strip():
            body.append("")
            continue
        if not paragraph_open and len(content) - len(content.lstrip(" ")) >= 4:
            literal = ("code", None, containers.copy())
            body.append("")
            continue
        marker = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", content)
        # Backtick fence info strings cannot contain backticks, even escaped
        # ones. An invalid opener remains ordinary Markdown.
        if marker and (marker[1][0] != "`" or "`" not in marker[2]):
            literal = ("fence", marker[1], containers.copy())
            paragraph_open = False
            body.append("")
            continue
        ending = html_block_end(content, paragraph_open)
        if ending is not None:
            if not ending.search(content):
                literal = ("html", ending, containers.copy())
            paragraph_open = False
            body.append("")
            continue
        if not paragraph_open:
            definition = read_definition(lines, line_index, content, containers)
            if definition is not None:
                identifier, target, skip_through = definition
                definitions.setdefault(identifier, target)
                all_targets.append(target)
                body.append("")
                continue
        # Inline parsing needs the projected paragraph, without repeated
        # container markers. Remove only that prefix from the original line:
        # tab expansion is for indentation, not for changing link/label bytes.
        inline_content = line
        prefix_columns = len(expanded_line) - len(content)
        if prefix_columns:
            column = 0
            for offset, char in enumerate(line):
                column += 4 - column % 4 if char == "\t" else 1
                if column >= prefix_columns:
                    inline_content = " " * (column - prefix_columns) + line[offset + 1:]
                    break
        body.append(inline_content)
        heading = re.match(r"^ {0,3}#{1,6}(?:[ \t]|$)", content)
        ends_paragraph = (heading or re.match(thematic_line, content)
                          or paragraph_open and re.match(setext_line, content))
        paragraph_open = not ends_paragraph
        if heading:
            # An ATX heading ends on its own line even without a blank.
            body.append("")

    # Inline code and HTML are skipped during scanning, preserving their raw
    # bytes inside an enclosing label instead of joining unrelated syntax.
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
# 4. Orphans — every docs page needs a navigation path from docs/README.md,
#    docs/AGENTS.md, or the root README/CONTRIBUTING/AGENTS.
# ---------------------------------------------------------------------------
if [ "$ORPHAN_CHECK" -eq 1 ]; then
    NAVIGATION_ROOTS="$LINK_CACHE/roots"
    for f in docs/README.md docs/AGENTS.md "${EXTRA_LINK_FILES[@]}"; do
        [ -f "$f" ] && printf '%s\n' "$f"
    done > "$NAVIGATION_ROOTS"

    # Keep source/target pairs on separate lines so spaces in filenames need
    # no encoding. Only the parsed navigation view contributes graph edges.
    NAVIGATION_EDGES="$LINK_CACHE/edges"
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
            printf '%s\n' "$f"
            normpath "$path"
        done
    done > "$NAVIGATION_EDGES"

    # Visit each reachable page once. Self-links and disconnected cycles do
    # not create entry points; nested indexes need a path like any other page.
    REACHABLE="$LINK_CACHE/reachable"
    if ! awk '
        FILENAME == ARGV[1] {
            if (!seen[$0]++) queue[++tail] = $0
            next
        }
        FNR % 2 { source = $0; next }
        { edges[source, ++count[source]] = $0 }
        END {
            for (head = 1; head <= tail; head++) {
                source = queue[head]
                print source
                for (edge = 1; edge <= count[source]; edge++) {
                    target = edges[source, edge]
                    if (!seen[target]++) queue[++tail] = target
                }
            }
        }
    ' "$NAVIGATION_ROOTS" "$NAVIGATION_EDGES" > "$REACHABLE"; then
        fail "unable to traverse documentation navigation"
        exit 1
    fi

    for f in "${FILES[@]}"; do
        case "$f" in
            docs/README.md|docs/AGENTS.md|docs/.private/*) continue ;;
        esac
        if ! grep -qxF "$f" "$REACHABLE"; then
            fail "$f: orphan (no navigation path from a documentation entry point — add it to a reachable README index)"
        fi
    done
fi

# ---------------------------------------------------------------------------
if [ "$ERRORS" -gt 0 ]; then
    printf 'docs-check: %d problem(s) in %d file(s)\n' "$ERRORS" "${#FILES[@]}" >&2
    exit 1
fi
printf 'docs-check: %d file(s) OK\n' "${#FILES[@]}"
