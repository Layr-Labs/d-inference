"""Extract the tag keys a tree emitted per metric name, in order.

Usage: python3 extract_tag_keys.py <tree-root>

Run it against a tree from before the catalog migration — see README.md. It
prints one `name<TAB>key,key,key` line per *distinct* key list observed, so a
metric emitted with two different tag sets (a conditional dimension) produces two
lines and the test can require the declaration to cover both.

Tag keys have to be readable from the source, which for the pre-catalog call
sites means one of two shapes: spelled at the call
(`[]string{"model:" + model, "mode:service_hold"}`) or hoisted to a slice
variable a line or two above and possibly appended to
(`tags := []string{...}` … `append(tags, "reason:early")`). Both are resolved,
the second by taking the nearest preceding assignment to that name. A site that
built its tags somewhere this cannot follow (the scheduler's gauge loop, which
carries them in a struct) leaves no evidence and is simply not asserted. Partial
coverage is the point — every name it does resolve is one whose declaration
cannot silently retag it.
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
    if not keys and body.strip(" ,\t\n") not in UNTAGGED:
        # Something is there and none of it was legible.
        resolved = False
    return ordered_unique(keys), resolved


def resolve(src, ident, before, depth):
    at = -1
    for m in ASSIGN.finditer(src, 0, before):
        if m.group(1) == ident:
            at = m.end()
    if at < 0:
        return [], False
    return keys_in(src, rhs_extent(src, at), at, depth)


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
