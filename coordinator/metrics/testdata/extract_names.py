"""Extract the metric names a tree emits, for coordinator/metrics/testdata.

Usage: python3 extract_names.py <tree-root> dd|mirror

Run it against a tree from before the catalog migration — see README.md. The
patterns below are the four ways a name was spelled before declarations existed:
at the recording call, bound to a `metricFoo` constant, in the mdm scheduler's
name-translation map, or in a struct literal the gauge loop iterates over.
"""
import os, re, sys

root, which = sys.argv[1], sys.argv[2]

# First string-literal argument of each recording call, across line breaks.
DD = re.compile(
    r'\b(?:ddIncr|ddCount|ddGauge|ddHistogram'
    r'|dd\.Incr|dd\.Count|dd\.Gauge|dd\.Histogram|dd\.LockedGauge)\(\s*"([^"]+)"'
)
# metricCounter is the mdm scheduler's own helper: its first argument is the
# in-process name, which it translates to a DogStatsD name via MAPPED below.
MIRROR = re.compile(
    r'\b(?:IncCounter|AddCounter|ObserveHistogram'
    r'|RegisterGauge|RegisterGaugeLabels|metricCounter)\(\s*"([^"]+)"'
)
CONST = re.compile(r'\bmetric[A-Z][A-Za-z0-9]*\s*=\s*"([^"]+)"')
# The scheduler's translation map: in-process name -> DogStatsD name.
MAPPED = re.compile(r'"([a-z0-9_]+_total)"\s*:\s*"([^"]+)"')
# Gauges assembled as values and pushed in a loop (the scheduler's queue shape).
STRUCT_NAME = re.compile(r'\bname:\s+"([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+)"')

names = set()
for dirpath, _, files in os.walk(root):
    for f in files:
        if not f.endswith(".go") or f.endswith("_test.go"):
            continue
        src = open(os.path.join(dirpath, f)).read()
        mapped = MAPPED.findall(src)
        if which == "dd":
            names |= set(DD.findall(src)) | set(STRUCT_NAME.findall(src))
            names |= {dd for _, dd in mapped}
            names |= {n for n in CONST.findall(src) if not n.endswith("_total")}
        else:
            names |= set(MIRROR.findall(src))
            names |= {mirror for mirror, _ in mapped}
            names |= {n for n in CONST.findall(src) if n.endswith("_total")}
print("\n".join(sorted(names)))
