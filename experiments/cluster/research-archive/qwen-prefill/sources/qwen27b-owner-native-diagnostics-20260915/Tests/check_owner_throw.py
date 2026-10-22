#!/usr/bin/env python3
"""Actual owner error-path/defer check. Invalid open refuses before lease/native construction."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "owner-throw-check"
OUT.mkdir()
with tempfile.TemporaryDirectory(prefix="qwen27b-owner-diagnostic-") as raw:
    scratch = Path(raw)
    binary = ROOT / "build-1/artifacts/darkbloom-owner-qualification"
    shutil.copy2(binary, scratch / binary.name)
    for lib in (ROOT / "Dependencies").glob("*.dylib"):
        shutil.copy2(lib, scratch / lib.name)
    config = json.loads((ROOT.parent / "qwen27b-owner-jsonl-rerun-20260915/configuration/owner-rank0.json").read_bytes())
    config.update(workerExecutable=str(scratch / "never-created-worker"), modelDirectory=str(scratch / "no-model"),
                  leaseDirectory=str(scratch / "unused-lease"), workerEnvironment={})
    owner = scratch / "owner.json"
    owner.write_text(json.dumps(config, separators=(",", ":")) + "\n")
    owner.chmod(0o600)
    began = time.monotonic()
    with (OUT / "stdout").open("wb") as stdout, (OUT / "stderr").open("wb") as stderr:
        child = subprocess.Popen([str(scratch / binary.name), "cluster", "worker-owner", "--stdio"],
                                 stdin=subprocess.PIPE, stdout=stdout, stderr=stderr, start_new_session=True)
        try:
            child.communicate(input=b"{}\n", timeout=8)
        except BaseException:
            if child.returncode is None:
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                child.wait(timeout=5)
            raise
    records = []
    for line in (OUT / "stderr").read_bytes().splitlines():
        try:
            value = json.loads(line)
        except (ValueError, UnicodeDecodeError):
            continue
        if value.get("schema") == "qwen27b_owner_native_diagnostic_v1":
            records.append(value)
    assert child.returncode != 0 and not (OUT / "stdout").read_bytes()
    assert len(records) == 1, "defer must publish once after actual service throw"
    record = records[0]
    assert record["childConstructed"] is False and record["nativeCleanupObserved"] is False
    assert record["termination"] is None and record["diagnosticTailBytes"] == 0
    assert not (scratch / "unused-lease").exists(), "invalid open must not acquire canonical or test device lease"
    receipt = {"passed": True, "actualOwnerProcesses": 1, "nativeWorkerProcesses": 0,
               "noModelOrNetwork": True, "exitCode": child.returncode, "elapsedSeconds": time.monotonic() - began,
               "deferRecords": len(records), "noLeaseCreated": True,
               "ownerSHA256": hashlib.sha256(binary.read_bytes()).hexdigest(),
               "stderrSHA256": hashlib.sha256((OUT / "stderr").read_bytes()).hexdigest()}
    (OUT / "result.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    print(json.dumps(receipt, sort_keys=True))
