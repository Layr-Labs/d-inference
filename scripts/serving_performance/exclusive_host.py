"""Reject concurrent CI workers/builds/known inference runners, without recording argv."""
from collections import Counter
import os
from pathlib import Path
import subprocess


def classify_processes(snapshot, owned_group=None, supervisor_pid=None):
    found = Counter()
    processes = []
    for line in snapshot.splitlines():
        columns = line.strip().split(None, 3)
        if len(columns) != 4:
            continue
        try:
            pid, parent, group = map(int, columns[:3])
        except ValueError:
            continue
        processes.append((pid, parent, group, columns[3]))
    owned = {supervisor_pid}
    if owned_group is not None:
        owned.add(owned_group)
    while True:
        previous = len(owned)
        owned.update(pid for pid, parent, group, _ in processes
                     if parent in owned or owned_group is not None and group == owned_group)
        if len(owned) == previous:
            break
    for pid, _, _, command in processes:
        if pid in owned:
            continue
        name = Path(command).name.lower()
        category = None
        if name == "runner.worker": category = "ci_worker"
        elif name in ("swift-build", "swift-frontend", "clang", "metal"): category = "compiler"
        elif (name == "darkbloom" or name.startswith(("providerbenchmark", "kv-", "mlx-", "llama-", "ollama"))
              or name.endswith("packagetests") or name in ("xctest", "lm studio")):
            category = "inference_or_test_runner"
        elif name.startswith("python"):
            category = "other_python_work"
        if category:
            found[category] += 1
    return dict(sorted(found.items()))


def foreign_work(owned_group=None):
    try:
        snapshot = subprocess.check_output(["/bin/ps", "-axo", "pid=,ppid=,pgid=,comm="], text=True, timeout=5)
        return classify_processes(snapshot, owned_group, os.getpid())
    except (OSError, subprocess.SubprocessError):
        return {"process_inventory_unavailable": 1}
