# Process admission and native ownership integration

> Last updated: 2026-09-05 · commit `51e210e14`

Typed model-load claims and native paged ownership now share one process admission
ledger. The native connection is optional; production factory binding and
allocator-footprint sizing remain release gates. This record proves ownership
and post-allocation accounting, not a real-model speedup or rollout readiness.

## Change

`GlobalKVCacheBudget` retains actor policy, correlation, diagnostics and off-actor
reclamation. `ProcessMemoryLedger` owns synchronous byte admission. Model loads
atomically claim padded target/assistant weights plus the existing setup
allowance, recheck after asynchronous preparation, and reduce that same typed
handle as phases finish. Delayed cleanup cannot release a successor with the
same request string. The unconditional pending-load APIs and arithmetic
read/add-back recheck are deleted. The setup allowance survives slot installation.

`EngineProcessMemoryOwner` connects native Admission to that ledger before the
engine loop starts. Native Admission projects its complete charge before local
metadata changes. Evaluated paged backing carries one materialization credit
through shared checkpoint wrappers. Withdrawal precedes backing retirement;
closing preserves live charges and permits already reserved work to drain.
Repeated empty teardown never calls a removed owner generation.

Capacity readers use one coherent allocator/ownership snapshot and subtract only
unmaterialized promises. For committed bytes C and credited materialized bytes M,
the process projection is `U + Σ(C − M)`. Existing cap, OS/load reserve and serving
activation policy remain in force. Allocator initialization stays outside ledger
locks and public budget construction remains lazy.

## Validation

Parent base: `51e210e143cc17cccc63df2eafcbacd65a50389c`.
Native commit: `f93134e537c594f6b5c69fb08115062c205cf655`.
MLX-Swift: `eafd98a7c53c145ff40faa486c5f696b7104ae92`.
Nested MLX: `9b3f4d1ec6bd65314e06825658334e5788ee3167`;
mlx-c: `720953eff635e772d9f3d73e46942bc49fac04c3`.

| Check | Result | Scope |
|---|---|---|
| Native process ownership and affected paging/admission suites | 135 unique functions, 169 actual cases; 120.96 s build | Includes 7 new native lifetime/refusal cases; fake process capacity owner |
| Combined provider process/budget/load/MTP/policy suites | 195 unique functions, 196 actual cases; 78.68 s build | All pass, no skips; includes 2 real native allocator cases |
| Actual native/pool/provider integration | 2 cases, 0.495 s | Existing internal test access; actual Admission, paged allocation, adapter and coherent MLX readings |
| Source identity | Unchanged before/after | 32 owned paths, 1,134 selected provider/native/Jinja inputs and 1,353 MLX inputs; actual compiler graph verified |
| Permanent invocation | Shell syntax checked | CI and `make provider-test` share `scripts/run-provider-tests.sh`; the allocator-sensitive suite runs separately with the existing nonzero/no-skip guard |

The CI workflow itself and the entire provider aggregate were not rerun for this
record. The focused groups compile the full provider test bundle. The isolated
suite prevents unrelated MLX tests from perturbing exact allocator assertions.

### Actual allocator observations

| Phase | Observed bytes |
|---|---|
| Evaluated native pages | Native C=M=65,536; actual allocator U=81,928 |
| Competing owner | 4,096 accepted at cap 86,024; one more byte refused |
| Retained raw array alias | Logical array bytes 24,576; allocator retention 32,768 |
| Native owner retired, alias retained | C=M=0; active allocator bytes 32,772 |
| Last alias drained | Active allocator bytes 4; competing owner can grow |

These observations expose an additional requirement: MLX rounds allocations and
may reuse a larger cached buffer. Logical `nbytes` is a valid lower-bound M credit,
but it does not price the entire allocation before it exists. The current process
projection correctly includes the difference through U after allocation. An
allocator-owned preallocation bound and actual evaluated buffer footprint are
required before claiming tight-cap allocation safety or final capacity parity.
No global before/after difference is used to credit an individual owner.

## Evidence and remaining gates

[Evidence manifest](evidence/process-memory-admission-2026-09-05/manifest.json)
contains 119 verified payloads in one archive, including commands, compiler graph,
identifiers, source hashes, phase observations and exact source freezes.
Manifest SHA-256: `82dfb67d4660b930c6fbac1eee71e08be86522cf6e13122f2af1174dda2a3c7b`.
Archive SHA-256: `9ee5fdf9704d878dcafe35a5def0bc15f358806718a252d013102b5d394fbcbe`.

This milestone does not establish production factory binding, contiguous or
recurrent/MTP/scratch materialization, complete paged SSD serving, runtime dtype
fault handling, five-model equivalence, B1/B2/B4 performance, HTTP/tool/vision
coverage, persistent-key restart or release promotion. Those gates remain open.
