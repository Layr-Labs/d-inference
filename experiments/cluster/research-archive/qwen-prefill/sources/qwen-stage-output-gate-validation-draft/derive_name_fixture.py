#!/usr/bin/env python3
"""Extract unchanged names from retained header metadata, without payload reads."""
from pathlib import Path
import hashlib
import json

HERE = Path(__file__).resolve().parent
SOURCE = HERE.parent.parent / "models/Qwen3.8-27B/weight-layout.json"


def main():
    raw = SOURCE.read_bytes()
    source_sha = hashlib.sha256(raw).hexdigest()
    assert source_sha == "2e03d0192ebb5d392c487582a3c4d1d8466fbf483c8d18bee4f9cb298997070b"
    data = json.loads(raw)
    names = sorted(name for name in data["tensors"] if name.startswith("language_model."))
    assert len(names) == len(set(names)) == 1847 and len(data["tensors"]) == 2211
    result = {"schemaVersion": 1, "kind": "qwen27_retained_canonical_name_fixture",
        "sourcePath": str(SOURCE), "sourceKey": "tensors", "sourceSHA256": source_sha,
        "selection": "dictionary keys beginning language_model.; unchanged strings, sorted",
        "canonicalSourceNames": names, "nameCount": len(names), "excludedNameCount": 364,
        "modelPayloadRead": False, "constructedInventoryOrPayloadVerificationClaimed": False}
    output = json.dumps(result, sort_keys=True, separators=(",", ":")).encode() + b"\n"
    assert SOURCE.read_bytes() == raw
    (HERE / "canonical-27b-name-fixture.json").write_bytes(output)
    print(json.dumps({"nameCount": len(names), "byteCount": len(output),
        "sha256": hashlib.sha256(output).hexdigest()}, sort_keys=True))


if __name__ == "__main__":
    main()
