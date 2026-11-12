"""Read-only preimage, postimage and focused MAIN context checks; no execution."""
import argparse
import hashlib
import json
from pathlib import Path

BASE = Path(__file__).resolve().parent


def raw(path):
    path = Path(path)
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 400_000:
        raise ValueError(f"Unsafe or oversized source: {path}")
    return path.read_bytes()


def sha(value):
    return hashlib.sha256(value).hexdigest()


def read_loop(value):
    start = value.index(b"    private func readLoop(_ pipe: ClusterOwnerPipe) {")
    end = value.index(b"    private func accept(_ frame: OwnerWire) throws {")
    return value[start:end]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--main-state", choices=("before", "after"), default="before")
    args = parser.parse_args()
    integration = json.loads(raw(BASE / "integration.json"))
    context = json.loads(raw(BASE / "main-context.json"))
    relative = integration["path"]
    before = raw(BASE / "original" / relative)
    after = raw(BASE / "proposed" / relative)
    old = b"                if !process.isRunning { throw ClusterWorkerOwnerError.closed }\n"
    new = b"                // Drain queued owner frames through actual pipe EOF, even after owner exit.\n"
    if before.count(old) != 1 or after != before.replace(old, new, 1):
        raise ValueError("Candidate changes more than the qualified EOF correction")
    if sha(before) != integration["beforeSHA256"] or sha(after) != integration["afterSHA256"]:
        raise ValueError("Retained preimage/postimage differs")
    for row in integration["sourceProvenance"]:
        value = raw(row["path"])
        if len(value) != row["bytes"] or sha(value) != row["sha256"]:
            raise ValueError(f"Retained provenance differs: {row['path']}")
    provenance = integration["sourceProvenance"]
    original = next(row for row in provenance if "/original/" in row["path"])
    proposed = next(row for row in provenance if "/proposed/" in row["path"])
    if read_loop(before) != read_loop(raw(original["path"])) or read_loop(after) != read_loop(raw(proposed["path"])):
        raise ValueError("Read-loop source equivalence differs")
    for row in context["files"]:
        value = raw(Path(context["root"]) / row["path"])
        expected = row["sha256"]
        if args.main_state == "after" and row["path"] == relative:
            expected = integration["afterSHA256"]
        if sha(value) != expected:
            raise ValueError(f"MAIN context differs: {row['path']}")
    print(json.dumps({"passed": True, "mainState": args.main_state,
        "focusedContextFiles": len(context["files"]), "runtimeFilesChanged": 1,
        "readLoopMatchesQualifiedPrivateSource": True, "compilerOrTestsRun": False,
        "mainMutated": False}, sort_keys=True))


if __name__ == "__main__":
    main()
