# Fresh c079 deployment on peer48

2026-09-15. Prepare a new `/Users/developer/DarkbloomDev/c079-runtime-20260915` directory. Its `repo` child is a real Git checkout; `bundle`, `launcher`, `inputs`, and `provenance` are siblings. This package neither rebuilds nor executes c079, touches an existing checkout, downloads model data, or establishes model numerics/performance. The newer aa7d resident-worker prototype is outside this deployment.

The existing peer24 installer cannot initialize this checkout: it requires all 536 prior-overlay files already present. `install_fresh.py` instead verifies the existing six Git bundles, clones their actual history at the pinned commits, registers submodules without downloading, applies the frozen 560-file overlay, and installs the unchanged read-only five-member native bundle. It then calls the **unchanged** `prefill_compute_archive.archive_sources` against the new repository, requires exact equality of all 403 frozen file records, and checks the complete recursive dependency path/commit set plus clean tracked dependency state. There is no fabricated `.git` directory or copied dependency receipt.

## Inputs already available locally

| Input | Location under `cluster-research` | Expected SHA-256 |
|---|---|---|
| Six Git bundles and manifest | `source-transfer-20260914/source-{0..5}.bundle`, `manifest.json` | Manifest `e0512837845a765aebd4f14b8e825f4ef99a9ad2e17c67f87c2483bba153ed2b` |
| c079 tar, manifest, source manifest | `peer24-short-parity-package-20260914/` | Tar `78bd7f09917a9a27a922fa503e612fe95ec1943d964eaeda8860a32647b885b6` |
| This installer, frozen parent, raw 3+1 inputs | `peer48-c079-deployment-draft/` | See `manifest.json`; parent `5b6ce0b93cb6e5e5259fd62b2333e1efd062fb6242617d9d8e8fabbe39ab075f` |

Git bundles total **561,582,402 bytes**; native tar is **240,066,560 bytes**. No new large archive is needed. Original package/bundle/source bytes remain untouched. The copied parent includes its 19 fabricated tests and historical source records; this installer never invokes its model-running entry.

Root has started staging the six Git bundles at `/Users/developer/DarkbloomDev/cluster-research/peer48-source-transfer-20260915`. Also copy the original `source-transfer-20260914/manifest.json` there. Stage only `package.tar`, `manifest.json`, and `source-manifest.json` from the c079 package in a new `/Users/developer/DarkbloomDev/cluster-research/peer48-c079-package-inputs-20260915`. Transfer this entire small draft to its same-named research directory. Do **not** run the old peer24 `install.py`.

## Exact operator steps on peer48

First verify destination absence, ownership, free disk space and the staged bytes; root's inventory reports 217 GiB available, Git 2.50.1, and no relevant checkout. The unrelated `mlxfast-challenge-dev` project is unnecessary. No Swift toolchain or model file is consumed by installation.

```sh
python3 -B /Users/developer/DarkbloomDev/cluster-research/peer48-c079-deployment-draft/install_fresh.py \
  --git-transfer /Users/developer/DarkbloomDev/cluster-research/peer48-source-transfer-20260915 \
  --native-package /Users/developer/DarkbloomDev/cluster-research/peer48-c079-package-inputs-20260915 \
  --verify-only

python3 -B /Users/developer/DarkbloomDev/cluster-research/peer48-c079-deployment-draft/install_fresh.py \
  --git-transfer /Users/developer/DarkbloomDev/cluster-research/peer48-source-transfer-20260915 \
  --native-package /Users/developer/DarkbloomDev/cluster-research/peer48-c079-package-inputs-20260915 \
  --destination /Users/developer/DarkbloomDev/c079-runtime-20260915
```

The installer refuses any existing destination and retains a partially installed directory on failure; do not rerun over it. A successful receipt is `c079-runtime-20260915/install-receipt.json`. Inspect this and `provenance/source-manifest.json`, then run the inherited CPU tests from the new `launcher` directory with `python3 -B -m unittest -v test_short_parity`. Model execution remains a separate root-owned step, with the unchanged parent and its existing controls.

The parent arguments become `--runtime /Users/developer/DarkbloomDev/c079-runtime-20260915/repo/experiments/cluster/runtime`, `--release` and `--reuse-bundle /Users/developer/DarkbloomDev/c079-runtime-20260915/bundle`, and the two raw files under its `inputs/`. Keep native SHA `c07954680b1c2d4582d1f200d6dbf850331849fb61b0209ac919a0784c2ba708`, bundle manifest SHA `50c581dc4ec15fd155b921b90a2b1579e6cc3fcbb8c6ec4b6ff577200a915a92`, prompt SHA `9c6bc7ac937d2daffe5ecdbe7eb3a59aba4f43e96a58a99f08838d4ce48c92ba`, and teacher SHA `9d1f4e3a2170ce5f947bcdfa249a77885875b0d9d7af88ad3fbc7f7cd7a224fa`. Choose a fresh run directory outside repository, model, and release; retain the exact metadata, source, bundle, native stdout/stderr, and parent receipt for the already frozen numerical/binding auditors.

## Exact dependencies and remaining evidence

Repository HEAD is `e4df336bc8399f4fd0a46d1207b594d2514f14f5`. Required submodules are `libs/mlx` and `libs/mlx-swift/Source/Cmlx/mlx` at `3fa8f25e6451174d7b06be372c3a24272b77d88e`; `libs/mlx-swift` at `6d6796d7a81b656d2749d39067e0a6bea2bc2986`; `libs/mlx-swift/Source/Cmlx/mlx-c` at `02cf6f4d099023e4e0c0357248b8b3f83110e29d`; and `libs/mlx-swift-lm` at `ce446cc5f76e013855fe0bde9002b6db1ac091b7`. Detached clone descriptions in Git's status may differ from the original branch-name decorations. Preserve the genuine new output: do not substitute the old status string. The source-manifest hash also changes because its repository path changes; its **403 file records** must remain identical.

Local input hashing and Python 3.9 AST parsing passed; remote verification, installation, cloned-checkout/archive execution, and post-install tests are pending. Root reports the 48 GiB machine's model download is still completing: the first shard was 3.41/5.35 GB, with the other 11 files hash-verified. Complete and verify the registered model before invoking the parent. Its native full-reference gate independently requires at least 10.453123 GiB actual free **before allocator rounding**, plus a separate active/cache-aware allocator-limit predicate, zero swap and all existing controls. Neither 48 GiB physical capacity nor this deployment proves admission or parity.
