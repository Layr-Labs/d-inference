This wrapper builds the frozen `98a051061c971046901b913ff20f86fb81642f5f6c6714ba9baf4ac68409f591` Lab RDMA component against the exact qualified protected native7 workspace/cache. It adds seven Swift files and replaces only the worker Package manifest. The source inventory changes from 3,081 to 3,088; all 9,832 dependency entries must remain exact. No current MAIN source is substituted.

The wrapper is source-only until root schedules it. The commands below are sequential; their output directories are create-only. A failure retains partial sources, logs and receipts and requires a separately reviewed retry. Do not delete a failed output or rerun preparation automatically.

```sh
python3 -B /Users/developer/DarkbloomDev/cluster-research/cluster-lab-encrypted-rdma-build-20260920/check_sources.py
python3 -B /Users/developer/DarkbloomDev/cluster-research/cluster-lab-encrypted-rdma-build-20260920/prepare.py
python3 -B /Users/developer/DarkbloomDev/cluster-research/cluster-lab-encrypted-rdma-build-20260920/run.py
python3 -B /Users/developer/DarkbloomDev/cluster-research/cluster-lab-encrypted-rdma-build-20260920/package_native.py
```

`prepare.py` first checks every existing source and dependency, all seven destination absences, the Package preimage and the actual native7 worker hash. It preserves the prior worker and Package in `preparation-1` before applying the eight overlays. It neither clones nor resolves the compiled cache. The original native7 bundle and all prior evidence remain unchanged.

`run.py` creates `build-1`, then builds only `LabAuthenticatedRDMABenchmark`, release, jobs2, macOS26.2, with resolution/update disabled. The exact previously reviewed owned-child helper bounds compilation at900s with10s cleanup; post-reap process-group checks are observation only. It checks the actual Mach-O deployment target and JACCL symbol before running metadata controls. Compiler output is retained even when compilation or final source checking fails. Source/dependency inventories are checked before compilation, after compilation and after all controls; new checkouts or Package.resolved changes are failures.

The six metadata steps are `local-contract`, `describe`, `check-arguments`, `wrong-identity`, `wrong-size`, `wrong-rank`, each with a15s owned-child bound. `--check-local` requires all eight exact native codec/contract labels. The other commands use the pinned public `metadata-job.json` only; invalid identity, payload size and rank must exit1 with the exact generic error and empty stdout. No command selects `--execute`, creates an RDMA group, provides a secret, or runs model/GPU work. The public fixture is never a physical job.

`build-1/receipt.json` supplies the physical binder's agreed fields: product, exitCode, compilerReaped, gpuExecuted, nativeSHA256, nativeBytes and sourcesSHA256. It also carries the exact source/dependency receipt references, actual resources and `nativeMetadataReceipt`. `sources.json` contains all3,088 actual source rows; `dependencies.json` contains all9,832 actual dependency rows. `build-1/metadata/receipt.json` supplies nativeSHA256, passed, metadataOnly and the ordered six groups, plus raw command receipts and the eight labels. Actual binary and source hashes are not predicted.

`package_native.py` checks the successful build/metadata and all source bytes again, then creates `native-bundle-1` with the actual executable, matching `mlx.metallib`, and `mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal`. Each APFS clone is an owned30s child and is verified afterward. Its receipt binds the successful build and metadata receipts. The physical binder separately adds its pinned matrix and actual strict-SSH host observations; this wrapper supplies neither host observations nor a physical grant.

The bounded source review in `source-review.json` found no counter/nonce/domain blocker. Operation timings include completion/resource checks, fixed mode order and instrumentation retention; they are component observations. This build does not establish verified Darkbloom membership, model performance, whole-process resource admission, or physical process/lease retirement.
