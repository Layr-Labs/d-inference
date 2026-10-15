"""Prepare one isolated derivative of the existing full-reference build."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent
RESEARCH = ROOT.parent
BASE = RESEARCH / "full-generation-reference-entry-build-20260915"
DRAFT = RESEARCH / "qwen-registered-generation-reference-draft-20260915"
WORK = ROOT / "workspace"
PACKAGE = Path("experiments/cluster/inference")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_base():
    pins = json.loads((BASE / "build-1/source-pins.json").read_text())
    for name, pin in pins.items():
        assert digest(BASE / "workspace" / PACKAGE / name) == pin, name
    return len(pins)


def source_members(root):
    result = {}
    for directory, dirs, files in os.walk(root, followlinks=False):
        dirs[:] = sorted(d for d in dirs if d not in {".git", ".build", "__pycache__"})
        for name in sorted(files):
            if name == ".git":
                continue
            p = Path(directory) / name
            if not p.is_symlink():
                result[str(p.relative_to(root))] = digest(p)
    return result


def main():
    assert not WORK.exists(), "Never overwrite a prepared workspace"
    base_count = verify_base()
    overlay = json.loads((DRAFT / "source-snapshot-1.json").read_text())
    for row in overlay:
        assert digest(DRAFT / row["path"]) == row["sha256"]
    subprocess.run(["/bin/cp", "-cR", str(BASE / "workspace"), str(WORK)], check=True)
    dependencies = {}
    for name in ["mlx-swift", "mlx-swift-lm"]:
        link = WORK / "libs" / name
        assert link.is_symlink(), str(link)
        source = link.resolve(strict=True)
        before = source_members(source)
        link.unlink()
        shutil.copytree(source, link, symlinks=True,
                        ignore=shutil.ignore_patterns(".git", ".build", "__pycache__"))
        assert source_members(link) == before == source_members(source)
        dependencies[name] = {"source": str(source), "members": before}
    rebased = []
    old = str(BASE / "workspace")
    for directory, dirs, files in os.walk(WORK / PACKAGE / ".generated-dependencies", followlinks=False):
        for name in dirs + files:
            p = Path(directory) / name
            if p.is_symlink():
                target = os.readlink(p)
                assert target.startswith(old + "/"), str(p)
                p.unlink()
                p.symlink_to(str(WORK) + target[len(old):])
                assert p.exists(), str(p)
                rebased.append(str(p.relative_to(WORK)))
    for row in overlay:
        target = WORK / PACKAGE / "Sources/ClusterInference" / Path(row["path"]).name
        shutil.copyfile(DRAFT / row["path"], target)
        assert digest(target) == row["sha256"]
    # Only the cloned build metadata is rewritten. The old cache and objects
    # remain untouched; Swift rebuilds stale inputs in this owned scratch tree.
    replacements = [(old.encode(), str(WORK).encode())]
    for name, row in dependencies.items():
        replacements.append((row["source"].encode(), str(WORK / "libs" / name).encode()))
    rewritten = []
    cache = WORK / PACKAGE / ".build"
    for directory, dirs, files in os.walk(cache, followlinks=False):
        dirs[:] = [d for d in dirs if d not in {"checkouts", "repositories", ".git"}]
        for name in files:
            p = Path(directory) / name
            if p.is_symlink() or p.suffix not in {".json", ".yaml", ".txt"} and name not in {"sources", "description"}:
                continue
            raw = p.read_bytes()
            changed = raw
            for before, after in replacements:
                changed = changed.replace(before, after)
            if changed != raw:
                p.write_bytes(changed)
                rewritten.append(str(p.relative_to(WORK)))
    quarantined = []
    for p in list(cache.glob("**/ModuleCache")):
        if p.is_dir() and not p.is_symlink():
            dest = ROOT / ("previous-" + str(p.relative_to(cache)).replace("/", "-"))
            p.rename(dest)
            quarantined.append(str(dest.relative_to(ROOT)))
    assert verify_base() == base_count
    snapshot = source_members(WORK)
    (ROOT / "source-snapshot-1.json").write_text(json.dumps(snapshot, indent=2, sort_keys=True) + "\n")
    receipt = {"baseSourceCount": base_count, "basePinsUnchanged": True,
               "overlaySnapshotSHA256": digest(DRAFT / "source-snapshot-1.json"),
               "overlayFiles": len(overlay), "sourceCount": len(snapshot),
               "dependencies": dependencies, "rebasedSymlinks": rebased,
               "rewrittenClonedMetadata": rewritten, "quarantinedClonedModuleCaches": quarantined,
               "compilerExecuted": False, "modelExecuted": False}
    (ROOT / "preparation.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    print(json.dumps({k: receipt[k] for k in ["baseSourceCount", "overlayFiles", "sourceCount", "compilerExecuted"]}))


if __name__ == "__main__":
    main()
