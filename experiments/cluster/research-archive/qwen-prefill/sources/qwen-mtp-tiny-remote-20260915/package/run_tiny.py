"""One bounded tiny GPU correctness run on the 48 GB development Mac."""
import hashlib
import json
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parent
UPSTREAM = ROOT / "helpers"
sys.dont_write_bytecode = True
sys.path.insert(0, str(UPSTREAM))
from reference_resources import ResourceGate
from worker_contract import WorkerSpec, decode, require
from worker_processes import PipeWorkers


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    output = ROOT / sys.argv[1]
    output.mkdir(mode=0o700, exist_ok=False)
    build = json.loads((ROOT / "build-receipt.json").read_text())
    snapshot = ROOT / "source-snapshot.json"
    require(sha(snapshot) == build["sourceSnapshotSHA256"], "Wrong source snapshot")
    members = json.loads((ROOT / "package.json").read_text())["members"]
    for row in members:
        require(sha(ROOT / row["path"]) == row["sha256"], "Package changed before tiny run")
    directory = ROOT / "bundle"
    binary, metal = directory / "MTPTinyForwardCheck", directory / "mlx.metallib"
    require(sha(binary) == build["binarySHA256"], "Wrong tiny executable")
    require(sha(metal) == "2129f6132794d84243c02631bc7478417dba0e0dbd10467beab56c11bf20bdd2", "Wrong matched metallib")
    helpers = ["reference_resources.py", "worker_processes.py", "worker_contract.py", "stage_checks/common.py"]
    receipt = {"sourceSnapshotSHA256": sha(snapshot), "binarySHA256": sha(binary), "metallibSHA256": sha(metal),
        "helpers": [{"path": str(UPSTREAM / p), "sha256": sha(UPSTREAM / p)} for p in helpers],
        "scope": "Remote fabricated four-layer/H64/P5 GPU forward/history/proposal; no real artifact or distributed transaction",
        "timeoutSeconds": 60, "errors": []}
    started = time.monotonic()
    with (output / "resources.jsonl").open("w") as samples:
        def publish(value):
            samples.write(json.dumps(value, sort_keys=True) + "\n"); samples.flush()
        gate = ResourceGate(publish)
        spec = WorkerSpec((str(binary), "run-tiny-forward-on-gpu"),
            {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(Path.home())}, "solo", None)
        owner = PipeWorkers((spec,), output / "native", 60, gate)
        primary = None
        try:
            gate("prelaunch")
            owner.start()
            result = owner.collect("tiny-forward", lambda _, raw: decode(raw))[0]
            require(result["fixture"] == "fabricated-tiny-final-rank" and result["promptTokens"] == 5
                and result["targetFrontier"] == 5 and result["targetVerificationExecuted"] is False
                and result["registeredResourceGateExercised"] is False, "Wrong tiny result scope")
            require(0 <= result["unacceptedProposal"] < 128
                and 0 <= result["maximumTargetOutputDifference"] <= 0.00001
                and 0 <= result["proposalHiddenDifference"] <= 0.00001, "Tiny numeric gate failed")
            receipt["result"] = result
            owner.finish()
        except BaseException as error:
            primary = error
            receipt["errors"].append(type(error).__name__ + ": " + str(error))
        finally:
            try:
                if not owner.closed: owner.close()
            except BaseException as error:
                receipt["errors"].append("cleanup: " + type(error).__name__ + ": " + str(error))
                if primary is None: primary = error
            try: gate("postflight")
            except BaseException as error:
                receipt["errors"].append("postflight: " + type(error).__name__ + ": " + str(error))
                if primary is None: primary = error
        receipt.update(elapsedSeconds=time.monotonic()-started, exitCodes=[c.returncode for c in owner.children],
            launchedChildCount=len(owner.children),
            reaped=bool(owner.children) and all(c.returncode is not None for c in owner.children),
            childPIDs=[c.pid for c in owner.children],
            groupFenced=bool(owner.children) and all(c.pid in owner._fenced_groups for c in owner.children),
            cleanupErrors=owner.cleanup_errors, completeOutput=owner.complete_output, resourceSamples=gate.samples)
    receipt["status"] = "passed" if primary is None and not owner.cleanup_errors else "failed"
    for row in members:
        require(sha(ROOT / row["path"]) == row["sha256"], "Package changed during tiny run")
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, sort_keys=True), flush=True)
    if primary is not None: raise primary


if __name__ == "__main__": main()
