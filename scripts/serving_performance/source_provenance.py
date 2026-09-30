"""Bind isolated qualification copies to the exact local candidate source bytes."""
import hashlib
import json
import subprocess


SOURCE_DIRECTORIES = (
    "provider-swift/Sources", "provider-swift/Tests",
    "libs/mlx-swift-lm/Libraries", "libs/mlx-swift-lm/Tests",
    "libs/mlx-swift/Source", "libs/mlx-swift/Plugins", "libs/mlx-swift/cmake",
    "scripts/serving_performance",
)
SOURCE_FILES = (
    "provider-swift/Package.swift", "provider-swift/Package.resolved",
    "libs/mlx-swift-lm/Package.swift", "libs/mlx-swift-lm/Package.resolved",
    "libs/mlx-swift/Package.swift", "libs/mlx-swift/CMakeLists.txt",
    "scripts/run-serving-qualification.py", "scripts/assemble-deadline-receipts.py",
    "scripts/build-serving-qualification.py",
    "scripts/qualify-deadline-performance.py", "scripts/qualify-prompt-counts.py",
    "scripts/generate-prompt-count-corpus.py", "scripts/stage-test-metallib.sh",
    "scripts/fetch-metallib.sh",
)
IGNORED_PARTS = frozenset((".git", ".build", "__pycache__", ".pytest_cache"))


def source_file_digests(root):
    paths = set()
    for relative in SOURCE_DIRECTORIES:
        base = root / relative
        for path in base.rglob("*"):
            if path.is_file() and not IGNORED_PARTS.intersection(path.relative_to(base).parts):
                paths.add(path)
    paths.update(root / relative for relative in SOURCE_FILES if (root / relative).is_file())
    sources = {}
    for path in sorted(paths):
        hasher = hashlib.sha256()
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(8 * 1024 * 1024), b""):
                hasher.update(chunk)
        sources[str(path.relative_to(root))] = hasher.hexdigest()
    return sources


def source_tree_digest(root):
    return hashlib.sha256(json.dumps(source_file_digests(root), sort_keys=True,
                                    separators=(",", ":")).encode()).hexdigest()


def source_identity(root):
    tree = source_tree_digest(root)
    if (root / ".git").exists():
        def git(*args, cwd=root):
            return subprocess.check_output(["git", *args], cwd=cwd, text=True).strip()
        paths = ("provider-swift", "libs/mlx-swift-lm", "libs/mlx-swift", "scripts")
        return {"head": git("rev-parse", "HEAD"), "source_tree_sha256": tree,
                "dirty": bool(git("status", "--porcelain", "--untracked-files=all",
                                  "--ignore-submodules=none", "--", *paths)),
                "tracked_diff_sha256": hashlib.sha256(subprocess.check_output(
                    ["git", "diff", "HEAD", "--ignore-submodules=none", "--", *paths], cwd=root)).hexdigest(),
                "dependency_head": git("rev-parse", "HEAD", cwd=root / "libs/mlx-swift-lm"),
                "mlx_swift_head": git("rev-parse", "HEAD", cwd=root / "libs/mlx-swift"),
                "mlx_head": git("rev-parse", "HEAD", cwd=root / "libs/mlx-swift/Source/Cmlx/mlx"),
                "mlx_c_head": git("rev-parse", "HEAD", cwd=root / "libs/mlx-swift/Source/Cmlx/mlx-c")}
    # Export this manifest from the local Git worktree only after its signed
    # candidate is committed. The remote copy proves byte equality; it does not
    # independently attest a caller's claimed commit or clean flag.
    provenance = json.loads((root / "source-revision.json").read_bytes())
    if provenance["source_tree_sha256"] != tree:
        raise ValueError("transferred source does not match build provenance")
    return provenance
