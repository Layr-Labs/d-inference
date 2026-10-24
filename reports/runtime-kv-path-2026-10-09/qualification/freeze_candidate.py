#!/usr/bin/env python3
"""Copy an already-built qualification candidate and bind exact source/resources."""
import argparse
import hashlib
import json
import pathlib
import shutil
import subprocess


def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sources(root):
    paths = list((root / "provider-swift/Sources").rglob("*"))
    paths += list((root / "libs/mlx-swift-lm/Libraries").rglob("*"))
    paths += [root / "provider-swift/Package.swift", root / "libs/mlx-swift-lm/Package.swift"]
    return {str(path.relative_to(root)): sha(path) for path in sorted(paths) if path.is_file()}


def head(root):
    return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=pathlib.Path, required=True)
    parser.add_argument("--binaries", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--build-log", type=pathlib.Path, required=True)
    args = parser.parse_args()
    root, binaries = args.root.resolve(), args.binaries.resolve()
    before = sources(root)
    args.output.mkdir(parents=True, exist_ok=False)
    for name in ["darkbloom", "mlx.metallib"]:
        shutil.copy2(binaries / name, args.output / name)
    for bundle in sorted(binaries.glob("*.bundle")):
        subprocess.run(["/usr/bin/ditto", str(bundle), str(args.output / bundle.name)], check=True)
    if before != sources(root):
        raise RuntimeError("Source changed during candidate capture; do not qualify this output")
    for relative in ["libs/mlx", "libs/mlx-swift", "libs/mlx-swift/Source/Cmlx/mlx"]:
        subprocess.run(["git", "diff", "--exit-code", "HEAD"], cwd=root / relative, check=True)
    encoded = json.dumps(before, sort_keys=True, separators=(",", ":")).encode()
    receipt = {
        "source_file_digest": hashlib.sha256(encoded).hexdigest(), "source_files": before,
        "parent_head": head(root), "native_head": head(root / "libs/mlx-swift-lm"),
        "mlx_swift_head": head(root / "libs/mlx-swift"),
        "core_head": head(root / "libs/mlx-swift/Source/Cmlx/mlx"),
        "build_log_sha256": sha(args.build_log),
        "artifacts": {name: sha(args.output / name) for name in ["darkbloom", "mlx.metallib"]},
        "resources": {str(path.relative_to(args.output)): sha(path)
                      for path in sorted(args.output.glob("*.bundle/**/*")) if path.is_file()},
        "scope": "Loose developer-built qualification executable; not a signed or notarized release app.",
    }
    (args.output / "source-receipt.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    print(json.dumps({key: receipt[key] for key in ["source_file_digest", "artifacts", "scope"]}))


if __name__ == "__main__":
    main()
