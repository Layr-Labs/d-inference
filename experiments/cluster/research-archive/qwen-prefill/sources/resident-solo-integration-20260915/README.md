# One real resident solo cohort

This private launcher is ready for a root-owned run of the unchanged **aa7d** worker and V3 pipe adapter on the 48 GB Mac. It admits only the registered Qwen3.5 9B artifact and the retained 8,192-token diagnostic input: one load, one excluded warmup, three measured fresh requests, release, then explicit shutdown. It does not support distributed execution or MTP.

Copy this entire directory, including `reference/` and `stage_checks/`, to the remote research directory. Preserve the separately deployed `aa7d-runtime-20260915` package. From a new output location:

```sh
/usr/bin/python3 -B /Users/developer/DarkbloomDev/cluster-research/resident-solo-integration-20260915/run_solo.py \
  --deployment /Users/developer/DarkbloomDev/aa7d-runtime-20260915 \
  --model-dir /Users/developer/DarkbloomDev/models/Qwen3.5-9B \
  --output /Users/developer/DarkbloomDev/cluster-research/resident-solo-aa7d-20260915 \
  --cohort-id diagnostic:solo
```

The output parent must exist and the output directory must not exist. The deployment must contain the exact pinned manifest, 431 members and read-only five-file native bundle. The launcher verifies these bytes before launch and rechecks them after retirement. Model payload verification remains in the existing native loader; Python reads only pinned config/manifest metadata. All helper imports are local copies, never mutable repository or archived executable Python imports.

The adapter sends only `open` on entry. Each `run` grants exactly one predeclared UUID/epoch request. It validates ready/result/released/stopped fields, source/load/arithmetic identity, actual child PID and bundle paths, prompt/history identity, numerical digests, clock boundaries, native resource data and release accounting. Complete raw stdin/stdout/stderr remain in `pipes/`; `events/` preserves each validated original native JSON line without reencoding. The receipt retains partial results and failures; there is no retry. Native lifetime is 300 seconds and the V3 hard parent deadline is 315 seconds.

Parent polling enforces **6 GiB actual free**, zero reported swap, pressure ≤ 2 and AC. `vm_stat` already subtracts speculative pages in its “Pages free” field; no reclaimable-memory credit is used. Native observations additionally enforce normal power mode and nominal/fair thermal state before and after requests. Sampling is not a peak-memory or continuous thermal proof. The parent observes resources during the worker's timed execution; polling/validation overhead may affect this diagnostic run.

The fixed reference is the actual 2026-09-14 peer24 full-model 8K execution, stdout SHA `da85eb1e79a43c16575e6a8ffd48594ccb72306c16543a1e02c24903b89c154a`. Its full BF16 row is reconstructed and finite argmax checked. Candidate output supplies row/state metadata and hashes; all four requests must match that same-input reference exactly. Eight offset states are independently known; the other 64 state values and candidate tensor bytes are opaque. The original reference oracle was frozen before candidate access but after its native execution. A mismatch refuses the cohort; it does not authorize a tolerance change.

`elapsed_ns` spans fresh CBv2 state creation through finite argmax/scalar readback. It excludes load/readiness and final diagnostic capture/retirement. It is **not external-client TTFT**, a representative workload result, physical-cluster proof or performance qualification. The native result's conservative false qualification flags remain unchanged. Runtime hardware/NAX attestation is not established.

CPU validation: `python3 -B -m unittest -v test_solo` uses fabricated Python workers, strict field mutations and the retained reference. The launcher has not run an actual model during its preparation. `cpu-checks.json` records the executed checks and exact inputs; `manifest.json` binds this package. Test support `fabricated_solo.py` is never selected by the real CLI.
