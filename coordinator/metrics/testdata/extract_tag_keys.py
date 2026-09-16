"""Extract the tag keys a tree emitted per metric name, in order.

Usage: python3 extract_tag_keys.py <tree-root>

Run it against a tree from before the catalog migration — see README.md. It
prints one `name<TAB>key,key,key` line per *distinct* key list observed, so a
metric emitted from two call sites with two different tag sets produces two lines
and the test can require the declaration to cover both. A conditional dimension
*within* one call site is a different case: `append` under an `if` is read
statically, so both branches collapse into one line carrying the union. That is
safe under the subsequence rule — the shorter branch is a subsequence of the
union — but it means a line here is the widest set a site can emit, not
necessarily one it always emits.

Tag keys have to be readable from the source, which for the pre-catalog call
sites means one of three shapes: spelled at the call
(`[]string{"model:" + model, "mode:service_hold"}`); hoisted to a slice variable
a line or two above and possibly appended to (`tags := []string{...}` …
`append(tags, "reason:early")`), resolved by taking the nearest preceding
assignment to that name *within the same function*; or carried in a composite
literal beside the name, which is how the MDM scheduler's gauge loop pushes its
two gauges.

Anything else — a tags slice arriving as a parameter, or built by a call — is
recorded as `?` and not asserted. Partial coverage is the point: every name it
does resolve is one whose declaration cannot silently retag it, and a name it
cannot read is left alone rather than described wrongly.
"""
import os, re, sys

root = sys.argv[1]

# A recording call and the metric name it opens with. The argument text that
# follows is scanned to the matching paren, because these calls wrap.
CALL = re.compile(
    r'\b(?:ddIncr|ddCount|ddGauge|ddHistogram'
    r'|dd\.Incr|dd\.Count|dd\.Gauge|dd\.Histogram|dd\.LockedGauge)\(\s*"([^"]+)"'
)
# `metricCounter(name, labelName, labelValue)`: the in-process name and a single
# literal label key. The DogStatsD name it translates to is resolved by the
# caller of this script via the same map the names extractor reads.
METRIC_COUNTER = re.compile(r'\bmetricCounter\(\s*"([^"]+)"\s*,\s*"([a-z0-9_]+)"')
# `gauge{name: "mdm.scheduler.queue_depth", value: ..., tags: []string{...}}` —
# the MDM scheduler's gauge loop, which carries a name and its tags in a struct
# and pushes them from a variable, so neither is visible at the recording call.
STRUCT_NAME = re.compile(r'\bname:\s*"([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+)"')
# `"key:" + value` or `"key:literal"` inside an argument list, and a reference to
# a slice variable holding tags. Scanned with one alternation so the two interleave
# in source order, which is the order the tags reach the wire.
TAG_TOKEN = re.compile(r'"([a-z][a-z0-9_]*):|\b([a-zA-Z][A-Za-z0-9]*[Tt]ags|tags)\b')
# `tags := []string{...}`, `tags = append(tags, ...)` — the hoisted form.
ASSIGN = re.compile(r'\b([a-zA-Z][A-Za-z0-9]*[Tt]ags|tags)\s*(?::=|=)\s*')
# The scheduler's in-process name -> DogStatsD name translation.
MAPPED = re.compile(r'"([a-z0-9_]+_total)"\s*:\s*"([^"]+)"')
# A whole metric name. A call whose name is built by concatenation contributes
# only its literal prefix, which is not a name and must not be reported as one.
NAME_SHAPE = re.compile(r'^[a-z0-9]+([._][a-z0-9]+)*$')
# What a genuinely untagged site passes. Anything else that yields no keys is a
# site this script failed to read, which is a different fact and reported as one.
UNTAGGED = ("", "nil", "[]string{}", "[]string(nil)")
# The marker for "could not read the tags here". The test skips a name carrying
# it; a golden that claimed such a site had no tags would be a false fact, and the
# first migration of that metric would fail the test with a wrong accusation.
UNRESOLVED = "?"


def args_after(src, open_paren):
    """Text between open_paren and its match, ignoring parens inside strings."""
    depth, i, in_str = 0, open_paren, False
    while i < len(src):
        ch = src[i]
        if in_str:
            if ch == '\\':
                i += 2
                continue
            if ch == '"':
                in_str = False
        elif ch == '"':
            in_str = True
        elif ch == '(':
            depth += 1
        elif ch == ')':
            depth -= 1
            if depth == 0:
                return src[open_paren + 1:i]
        i += 1
    return ""


def ordered_unique(keys):
    out = []
    for k in keys:
        if k not in out:
            out.append(k)
    return out


def keys_in(src, body, before, depth=0):
    """Tag keys in body, in source order, resolving tag-slice variables.

    Returns (keys, resolved). `before` is the offset the reference was made at: a
    variable resolves to its nearest *preceding* assignment, which is what makes
    `tags = append(tags, ...)` terminate instead of resolving to itself.
    """
    keys, resolved = [], True
    for m in TAG_TOKEN.finditer(body):
        if literal := m.group(1):
            keys.append(literal)
        elif depth < 4:
            sub, ok = resolve(src, m.group(2), before, depth + 1)
            keys.extend(sub)
            resolved = resolved and ok
        else:
            resolved = False
    if not keys:
        # Nothing legible. Whether that is a fact or a failure is decided by the
        # last argument alone: ddGauge/ddCount/ddHistogram put a value between the
        # name and the tags, so testing the whole remaining body would read
        # `ddGauge(name, v, nil)` as illegible rather than as genuinely untagged.
        # A resolution that already failed still loses: `ddGauge(name, v, tags)`
        # with an unreadable `tags` must not be called untagged because some other
        # argument is nil — that is the one false fact this golden must never
        # carry.
        args = top_level_args(body)
        resolved = resolved and (not args or args[-1].strip() in UNTAGGED)
    return ordered_unique(keys), resolved


def top_level_args(body):
    """body split on the commas that separate arguments, ignoring nested ones.

    A backslash consumes the character after it, as in args_after: looking back
    one character instead would read the closing quote of `"c:\\\\"` as escaped
    and treat the rest of the argument list as string. Line comments are skipped
    for the same reason — these calls wrap, so a comment between two arguments is
    ordinary, and a prose comma in one would split an argument in half. They are
    dropped from the text as well as from the split, so `nil, // untagged` still
    compares equal to `nil`.
    """
    out, arg, depth, i, in_str = [], [], 0, 0, False
    while i < len(body):
        ch = body[i]
        if in_str:
            if ch == "\\":
                arg.append(body[i:i + 2])
                i += 2
                continue
            if ch == '"':
                in_str = False
        elif ch == '"':
            in_str = True
        elif body.startswith("//", i):
            nl = body.find("\n", i)
            i = len(body) if nl < 0 else nl
            continue
        elif ch in "{([":
            depth += 1
        elif ch in "})]":
            depth -= 1
        elif ch == "," and depth == 0:
            out.append("".join(arg))
            arg = []
            i += 1
            continue
        arg.append(ch)
        i += 1
    out.append("".join(arg))
    return [a for a in out if a.strip()]


def func_start(src, at):
    """Offset of the top-level func declaration enclosing `at`, or 0.

    Go has no name to reach a local in another function with, so an identifier
    that is not assigned inside this one is a parameter, a package-level symbol,
    or a call — none of which this script reads. Scanning the whole file instead
    reached the *previous* function's local `tags` and reported its keys, which is
    how `exact_cache.estimated_ttft_saved_ms` (whose `tags` is a parameter) came
    out carrying `outcome,tier` from the function above it.

    The boundary is the enclosing *top-level* func, not the enclosing lexical
    scope: a `tags` local to one closure stays visible to a reference in a sibling
    closure of the same func. No pre-catalog call site has that shape — an AST walk
    over the tree finds no reference whose nearest preceding assignment belongs to
    a different object — and reading true scopes means parsing Go, which is more
    machinery than a golden extractor should carry.
    """
    i = src.rfind("\nfunc ", 0, at)
    return 0 if i < 0 else i + 1


def resolve(src, ident, before, depth):
    at, begin = -1, -1
    for m in ASSIGN.finditer(src, func_start(src, before), before):
        if m.group(1) == ident:
            at, begin = m.end(), m.start()
    if at < 0:
        return [], False
    # References inside the right-hand side resolve against what came before
    # *this* assignment, not before the reference: `tags = append(tags, ...)`
    # otherwise matches itself, recurses to the depth cap and reports the site
    # unreadable, when the keys are right there on the line above.
    return keys_in(src, rhs_extent(src, at), begin, depth)


def literal_remainder(src, at):
    """The rest of the composite literal `at` sits inside, from at to its `}`."""
    depth, i = 0, at
    while i < len(src):
        ch = src[i]
        if ch in "{([":
            depth += 1
        elif ch in "})]":
            if depth == 0:
                break
            depth -= 1
        i += 1
    return src[at:i]


def rhs_extent(src, at):
    """The assignment's right-hand side, however many lines it spans.

    A composite literal is routinely written across lines
    (`tags := []string{\\n "method:" + r.Method,\\n ...}`), so stopping at the
    first newline reads the shape and none of the keys — which is how the first
    version of this script reported `http.requests` as untagged.
    """
    depth, i = 0, at
    while i < len(src):
        ch = src[i]
        if ch in "{([":
            depth += 1
        elif ch in "})]":
            depth -= 1
        elif ch == "\n" and depth <= 0:
            break
        i += 1
    return src[at:i]


observed = {}  # name -> set of tuples
translation = {}


def record(name, keys):
    if not NAME_SHAPE.match(name):
        return
    observed.setdefault(name, set()).add(tuple(keys))


for dirpath, _, files in os.walk(root):
    for f in files:
        if not f.endswith(".go") or f.endswith("_test.go"):
            continue
        src = open(os.path.join(dirpath, f)).read()
        translation.update(dict(MAPPED.findall(src)))
        for m in CALL.finditer(src):
            open_paren = src.index("(", m.start())
            body = args_after(src, open_paren)
            # Drop the leading metric-name literal so a name containing a colon
            # cannot be read as a tag key.
            body = body[body.index('"' + m.group(1) + '"') + len(m.group(1)) + 2:]
            keys, resolved = keys_in(src, body, open_paren)
            record(m.group(1), keys if resolved else [UNRESOLVED])
        for m in METRIC_COUNTER.finditer(src):
            record(m.group(1), [m.group(2)])
        for m in STRUCT_NAME.finditer(src):
            fields = literal_remainder(src, m.end())
            if (at := fields.find("tags:")) < 0:
                record(m.group(1), [UNRESOLVED])
                continue
            keys, resolved = keys_in(src, fields[at + len("tags:"):], m.end())
            record(m.group(1), keys if resolved else [UNRESOLVED])

# metricCounter names are in-process names; emit them under the DogStatsD name
# the scheduler translated them to, which is the name the catalog declares.
for inproc, dd in translation.items():
    if inproc in observed:
        for keys in observed.pop(inproc):
            record(dd, list(keys))

for name in sorted(observed):
    for keys in sorted(observed[name]):
        print(f"{name}\t{','.join(keys)}")
