#!/usr/bin/env python3
"""Record source identities for an uncommitted parent/submodule benchmark build."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def git(directory, *args):
    return subprocess.check_output(["git", "-C", str(directory), *args], text=True)


def snapshot(root):
    result = {}
    for relative in (".", "libs/mlx-swift-lm", "libs/mlx", "libs/mlx-swift",
                     "libs/mlx-swift/Source/Cmlx/mlx", "libs/mlx-swift/Source/Cmlx/mlx-c"):
        directory = root / relative
        if not (directory / ".git").exists():
            continue
        paths = set(git(directory, "diff", "--name-only", "HEAD").splitlines())
        paths.update(git(directory, "ls-files", "--others", "--exclude-standard").splitlines())
        hashes = {}
        for name in sorted(paths):
            path = directory / name
            if path.suffix in {".swift", ".metal", ".h", ".hpp", ".c", ".cc", ".cpp", ".resolved", ".go"}:
                hashes[name] = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None
        result[relative] = {"head": git(directory, "rev-parse", "HEAD").strip(),
                            "modified_source_sha256": hashes}
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--compare", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    result = snapshot(root)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    if args.compare and json.loads(args.compare.read_text()) != result:
        raise SystemExit("Source snapshot changed during build")
    print(f"Source identity recorded: {args.output}")


if __name__ == "__main__":
    main()
