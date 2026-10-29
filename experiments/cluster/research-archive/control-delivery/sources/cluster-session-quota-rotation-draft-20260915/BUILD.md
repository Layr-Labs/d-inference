All commands require root's compiler/run slot. No compiler, native model or remote run was performed for this freeze.

Use a fresh private copy of current MAIN with its matching owned Provider build cache; do not mutate MAIN's source or cache. The fourteen baseline pins and exact Package preimage must match. A cache copied from another path may require rebuilding its path-bound ModuleCache; retain any failure rather than rewriting source to accommodate stale cache paths.

```sh
python3 /Users/developer/DarkbloomDev/cluster-research/cluster-session-quota-rotation-draft-20260915/stage_overlay.py --workspace PRIVATE_CHECKOUT
```

Within `PRIVATE_CHECKOUT/provider-swift`, run these sequentially through the existing `PrivateChecks/check_process.py` wrapper (900 seconds per SwiftPM step, jobs two). Retain stdout, stderr and exact command receipts outside the frozen package. Snapshot all private Swift/Package inputs before/after, as in the prior full Provider builds.

```sh
swift test -j 2 --filter 'distributedLocal|distributedHTTP|HTTPOrigin|httpOrigin|clusterStatus|ClusterStatus'
swift build -j 2 --product DistributedRotationOwnerCheck
```

The first step retains all existing no-factory, terminal delivery and origin/deadline controls alongside the eight new unit methods. The executable target is private-only and links actual ProviderCore. It imports MLX types transitively but never loads or evaluates a model.

```sh
python3 PACKAGE/PrivateChecks/build_children.py --checkout PRIVATE_CHECKOUT --output FRESH_CHILDREN
python3 PACKAGE/PrivateChecks/run_cases.py --driver PRIVATE_CHECKOUT/provider-swift/.build/debug/DistributedRotationOwnerCheck --children FRESH_CHILDREN --output FRESH_CASE_OUTPUT
```

`PACKAGE` is this package's absolute path. The standalone child compiler uses the same private checkout's Protocol/Bootstrap/Process/Remote sources; each process is bounded and all input hashes rechecked. The five actual loopback HTTP cases run sequentially, each with a 60-second Swift alarm and 70-second owned-parent bound. Existing owner lifetime remains at most 20 seconds and each fabricated installed session keeps the actual 16-request quota and 10-second lifetime. Result JSON retains actual endpoint proof/exit values; missing-ACK/nonzero-exit cases must remain quarantined. Failed fixture directories and journals are retained. No maintenance recovery or canonical lease deletion is performed.
