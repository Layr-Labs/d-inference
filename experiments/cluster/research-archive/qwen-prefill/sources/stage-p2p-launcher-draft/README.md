# Bounded stage P2P launcher draft

This standalone launcher has not been executed against a native binary. The CPU tests inject fake processes/clocks and forbid subprocess/socket creation. No files in the repository were changed by this draft.

Root-run success command:

```sh
python3 /Users/developer/DarkbloomDev/cluster-research/stage-p2p-launcher-draft/launch_stage_p2p.py \
  --release /Users/developer/DarkbloomDev/d-inference/experiments/cluster/inference/.build/arm64-apple-macosx/release \
  --runtime /Users/developer/DarkbloomDev/d-inference/experiments/cluster/runtime \
  --output /Users/developer/DarkbloomDev/cluster-research/runs/stage-p2p-success-20260913 \
  --timeout-seconds 60 --scenario success
```

Output must not exist and must be outside the repository. There are no model/host/JACCL options. Each native rank receives `--mode stage-p2p-check --synthetic --transport loopback-test --timeout-seconds N --epoch HEX32`. Both use fresh distinct IPv4 loopback ports in a staged MLX_HOSTFILE, with MLX_RANK 0 or 1. Port allocation is the existing runtime's bind-both-then-release method; failed bootstrap is terminal, with no retry or backend fallback.

Before any native launch, the driver copies all inference Swift sources, Package.swift/Package.resolved/build.sh/dependency generator, all runtime Python and Markdown, dependency package manifests and .gitmodules; it records repository/submodule revisions and rejects tracked dependency modifications. The runtime modules are imported from this snapshot, and their existing bundle.snapshot copies the executable, metallib, resource bundle and exact rank supervisor/artifact verifier into a shared immutable bundle. Source files, dependency identity, copied bundle files, launcher files and rank configurations are hash-checked after the run. This binds observed source and build artifacts; it is not a reproducible-build proof.

The existing supervisor owns each native process group; this driver owns both supervisor processes. It cancels the whole active cohort on deadline, peer nonzero exit, missing/malformed terminal output, invalid identity, memory-probe failure or signal. Native group cleanup is delegated to the existing supervisor's finally block; the receipt claims observed supervisor reaping, not an independent native PID inventory. Root performs that inventory separately.

Every native JSONL line is bounded, valid UTF-8, duplicate-free and finite JSON. An optional first `stage_p2p_ready` record and exactly one terminal `stage_p2p_check` record per rank must bind schemaVersion1, epoch, rank, worldSize2, transport loopback-test and backend ring. The terminal additionally requires passed/correctnessOnly true, throughputMeasurementValid false, a common fixtureFingerprint and equally sized bounded case lists. Extra native case details and controlCases are retained unchanged. The separate CPU audit owns exact fixture/hash reconstruction; this launcher does not claim to have rederived payloads.

The memory gate samples macOS sysctl before/during/after: pressure must stay at or below2 and OS-reported swap-used must not increase from baseline. Raw observations and their printed precision are retained; they are not RSS, allocator admission, or single-page swap accounting. Monitoring failure cancels the cohort. The parent deadline is1–60seconds plus bounded cancellation/reaping and metadata checks; native/supervisor bounds remain independent.

Failure scenarios use distinct new output directories:

- `--scenario bootstrap-timeout --timeout-seconds 3` archives both rank configs but intentionally starts only rank0. It passes its failure expectation only if the parent cohort deadline fires and the started supervisor is reaped. The configured native/supervisor timeout has the same bound; an unexpected earlier native failure is recorded as inconclusive, not silently accepted or retried.
- `--scenario peer-loss --timeout-seconds 60` starts both ranks and, after both validated ready records, terminates rank0's supervisor. Its native group is retired by finally; the other rank must fail/be cancelled and both supervisors must be reaped. If the fixture finishes before injection, the scenario fails as inconclusive. No retry.

`receipt.passed` is scenario success; `cohort.passed`/`native_success` means actual positive native completion. Expected failure scenarios never claim native correctness, model forward parity, hardware transfer qualification or throughput.

CPU test recipe: `python3 -m unittest -v test_stage_p2p_launcher.py` from this folder. Tests cover exact argv/env, malformed identities/JSON, incomplete/duplicate output, fixture disagreement, success, deadline, missing peer, peer loss, early native failure, memory gating, and supervisor reaping through fake process objects. Actual native execution, OS memory queries, loopback bootstrap and PID inventory remain untested by this draft.
