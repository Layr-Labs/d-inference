"""Summarize run_arms.sh output: per arm ready time, Hi proxy, r0..r2 TTFT, warmup log lines, conditions."""
import re
import sys

for path in sys.argv[1:]:
    arm = None
    rows = []
    tag = None
    with open(path, errors="replace") as f:
        for line in f:
            m = re.match(r"=== \S+ (\S+) arm (\w) bundle=(\S+) warmup=(\w+) cache_dir_before=(\w+)(.*)$", line)
            if m:
                arm = {"model": m.group(1), "arm": m.group(2), "bundle": m.group(3), "warmup": m.group(4),
                       "cache_before": m.group(5), "cond": m.group(6).strip(), "ttft": [], "tok": [],
                       "wlog": [], "ready": "", "hi": "", "err": []}
                rows.append(arm)
                continue
            if arm is None:
                continue
            m = re.search(r"ready after ([0-9.]+)s", line)
            if m:
                arm["ready"] = m.group(1)
            m = re.search(r'hi \{"hi_total_ms": ([0-9.]+)', line)
            if m:
                arm["hi"] = m.group(1)
            m = re.search(r"\] r(\d) ttft_ms=([0-9.]+) prompt (\d+)", line)
            if m:
                arm["ttft"].append(float(m.group(2)))
                arm["tok"].append(int(m.group(3)))
            m = re.search(r"Shape warmup [^:]+: (.*)$", line)
            if m:
                arm["wlog"].append(m.group(1).strip())
            if "refusing" in line or "died" in line or "answered by pid" in line:
                arm["err"].append(line.strip())
    for r in rows:
        stamp = r["bundle"].split(".")[-1]
        print(f"{r['model']:22s} {r['arm']} id=..{r['bundle'].split('.')[3]}.{r['bundle'].split('.')[-2]}.{stamp[-4:]} "
              f"cache_before={r['cache_before']:3s} warmup={r['warmup']:3s} ready={r['ready']:>5s}s "
              f"hi={r['hi']:>7s}ms ttft={r['ttft']} tok={r['tok']} [{r['cond']}]")
        for w in r["wlog"]:
            print(f"    warmup: {w}")
        for e in r["err"]:
            print(f"    ERROR: {e}")
