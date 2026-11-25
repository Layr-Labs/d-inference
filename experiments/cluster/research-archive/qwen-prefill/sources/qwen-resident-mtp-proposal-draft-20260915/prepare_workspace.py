"""Prepare only pinned source bytes. No compiler, cache or model invocation."""
import hashlib
import json
from pathlib import Path
import shutil

HERE = Path(__file__).resolve().parent
BASE = HERE.parent / "qwen-resident-mtp-selected-load-draft-20260915"
BUILD = HERE.parent / "qwen-resident-mtp-proposal-native-build-20260915"
SNAPSHOT_SHA = "e6b6126fc28258843e3ba7e85ccb12857e005ecde6c8e2f49d95dc6b8334e37d"
INVERSE_SHA = "2b44431180d4b1d93c5ea29c589b973802a43311454077bc444545ca4d254f87"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def member(root, path):
    data = (root / path).read_bytes()
    return {"path": path, "bytes": len(data), "sha256": digest(data)}


def main():
    raw = (BASE / "handoff/build-source-snapshot.json").read_bytes()
    assert digest(raw) == SNAPSHOT_SHA
    source = json.loads(raw)["members"]
    assert len(source) == 3048
    inverse = (HERE / "source-checks/off-inverse.json").read_bytes()
    assert digest(inverse) == INVERSE_SHA
    proposed = sorted(p.relative_to(HERE / "proposed").as_posix()
                      for p in (HERE / "proposed").rglob("*") if p.is_file())
    assert len(proposed) == 8
    for item in source:
        path = Path(item["path"])
        assert not path.is_absolute() and ".." not in path.parts
        assert member(BASE / "workspace", item["path"]) == item
    for item in json.loads((HERE / "base.json").read_bytes())["mainFiles"]:
        assert digest((BASE / "workspace" / item["path"]).read_bytes()) == item["sha256"]
    BUILD.mkdir(exist_ok=False)
    workspace = BUILD / "workspace"
    for item in source:
        path = item["path"]
        destination = workspace / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(BASE / "workspace" / path, destination)
    replacements = []
    for path in proposed:
        destination = workspace / path
        before = member(workspace, path) if destination.exists() else None
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(HERE / "proposed" / path, destination)
        replacements.append({"path": path, "before": before, "after": member(workspace, path)})
    members = [member(workspace, p.relative_to(workspace).as_posix())
               for p in sorted(workspace.rglob("*")) if p.is_file()]
    assert len(members) == 3054
    snapshot = json.dumps({"members": members}, indent=2) + "\n"
    (BUILD / "source-snapshot-1.json").write_text(snapshot)
    receipt = {"baseSnapshotSHA256": SNAPSHOT_SHA, "sourcePreservationSHA256": INVERSE_SHA,
               "sourceCount": len(members), "sourceSnapshotSHA256": digest(snapshot.encode()),
               "overlays": replacements, "compilerRun": False, "modelRun": False}
    (BUILD / "preparation.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps({k: v for k, v in receipt.items() if k != "overlays"}))


if __name__ == "__main__":
    main()
