#!/usr/bin/env python3
"""Stage actual-entry metadata cases; no compiler, native process, or model read."""
import argparse
import copy
import hashlib
import json
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument("--job", type=Path, required=True)
p.add_argument("--output", type=Path, required=True)
a = p.parse_args()
raw = a.job.read_bytes()
if len(raw) > 16384:
    raise SystemExit("job exceeds16384 bytes")
job = json.loads(raw)
assert job["schema"] == "gemma4_resident_benchmark_v1"
assert job["promptCount"] == 128 and job["chunkSize"] in (64,128) and job["outputCount"] == 16
assert job["cut"] in (6,7,8,10) and len(set(job["requestIDs"])) == 4
assert len(job["promptFileSHA256"]) == len(job["buildIdentitySHA256"]) == 64
# Caller supplies a real valid P128 job; all metadata paths/hashes are preserved.
cases = [("accepted", {}, True), ("accepted-cut6", {"cut": 6}, True), ("accepted-cut7", {"cut": 7}, True),
         ("accepted-chunk64", {"chunkSize": 64}, True), ("accepted-chunk128", {"chunkSize": 128}, True), ("unsupported-mode", {"mode": "stage2"}, False),
         ("unsupported-cut", {"cut": 9}, False), ("unsupported-prompt", {"promptCount": 32}, False),
         ("wrong-prompt-length", {"promptCount": 256}, False),
         ("unsupported-chunk", {"chunkSize": 32}, False), ("unsupported-output", {"outputCount": 17}, False),
         ("expired-bound", {"timeoutSeconds": 0}, False), ("excess-lifetime", {"timeoutSeconds": 301}, False),
         ("duplicate-request", {"requestIDs": [job["requestIDs"][0]] * 4}, False),
         ("missing-request", {"requestIDs": job["requestIDs"][:3]}, False),
         ("unsupported-dtype", {"residualDType": "int8"}, False),
         ("prompt-hash-mismatch", {"promptFileSHA256": "0" * 64}, False),
         ("bad-build-identity", {"buildIdentitySHA256": "unknown"}, False),
         ("noncanonical-path", {"modelDirectory": job["modelDirectory"] + "/../x"}, False),
         ("unknown-field", {"ignoredUnsafeOption": True}, False)]
a.output.mkdir(parents=False, exist_ok=False)
receipts = []
for name, delta, accepted in cases:
    value = copy.deepcopy(job)
    value.update(delta)
    encoded = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()
    path = a.output / (name + ".json")
    with path.open("xb") as stream:
        stream.write(encoded)
    receipts.append({"name": name, "path": str(path.resolve()), "sha256": hashlib.sha256(encoded).hexdigest(),
                     "expectedAccepted": accepted, "command": ["--check-arguments", str(path.resolve())]})
manifest = {"schema": "gemma4_benchmark_argument_cases_v1", "inputSHA256": hashlib.sha256(raw).hexdigest(),
            "cases": receipts, "executed": False, "requiresParentOwnedBoundedExecutor": True}
with (a.output / "cases.json").open("x") as stream:
    json.dump(manifest, stream, indent=2, sort_keys=True)
    stream.write("\n")
print(json.dumps({"cases": len(receipts), "executed": False, "output": str(a.output.resolve())}))
