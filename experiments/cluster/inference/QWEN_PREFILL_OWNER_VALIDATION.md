# Selected prefill owner intervals: solo and serial ranks

> Last updated: 2026-09-14 · commit `e4df336bc`

The optional eight-event owner recorder passed its local timing audit for a full-model solo request and for both serial layer stages. These were separate fresh invocations of the same executable on one 24 GiB M4 Pro GPU: one solo process, then two rank processes using loopback. The registered Qwen3.5-9B workload used 8,192 prepared prompt tokens, sixteen 512-token chunks, BF16 activations, one output token, and no teacher decode, warmup or repeats. See the [solo](QWEN_LONG_PREFILL_SOLO_VALIDATION.md) and [rank](QWEN_LONG_PREFILL_RANK_VALIDATION.md) numerical contracts.

Only zero-based chunk 7 was instrumented: token offset 3,584, width 512, committed frontier 4,096. Each owner sidecar is 1,770 bytes with exactly eight events. The unchanged 67-test owner auditor checked the full recorded-request/profile/role identity, exact event order and frontiers, monotonic UInt64 timestamps, and containment inside the corresponding coarse local chunk interval. The coarse traces retain 41 solo, 204 rank-0 and 235 rank-1 events.

| Selected chunk 7, local duration in ms | Graph construction | Root staging | Existing evaluation + error check | Validation / commit |
| --- | ---: | ---: | ---: | ---: |
| Solo, all 32 layers | 1.306042 | 0.009208 | 1149.663833 | 0.092541 |
| Rank 0, layers 0–15 | 0.729666 | 0.006834 | 574.042375 | 0.040000 |
| Rank 1, layers 16–31 | 0.870458 | 0.006958 | 575.025209 | 0.053208 |

These are four disjoint **host-clock intervals**, including recorder overhead. Graph construction may contain existing initialization work; evaluation includes the existing post-evaluation native/deadline check. The markers add no new evaluation or synchronization. They do not isolate GPU kernels or individual model operators. Gaps and other work within the enclosing chunk remain unclassified; neither difference measures overhead or transfer. Each row uses its own process clock: rank clocks are neither aligned nor summed.

The separate full-workload clocks were **18.602707708 s solo** and **18.783449250 s serial ranks**, with the latter measured by rank 0. Solo starts before fresh request state and stops after finite argmax/scalar readback; ranks start before start-send/fresh context and stop after final consumed acknowledgement and validated token return. Loading/readiness precede these clocks, and final diagnostic captures and retirement follow them. These two observations do not establish causal acceleration, observer overhead, physical Thunderbolt/RDMA performance, or the 27B/M3 Ultra prefill target. The [coarse phase contract](QWEN_PREFILL_PHASE_TRACE.md) and [serial phase validation](QWEN_PREFILL_RANK_PHASE_VALIDATION.md) explain the surrounding boundaries.

Separate unchanged numerical audits passed sixteen frames and the final reference comparison: 72 state components covering 319,946,784 logical bytes, a BF16 logit row of shape [1, 248320] covering 496,640 bytes, and selected token 271. Candidate state/logit equality covers metadata and digests; candidate native logit bytes and full-vocabulary values were not exported. Eight position offsets are reconstructed independently; 64 numerical state components remain opaque digests. Timing metadata does not independently prove these numerical results.

Both successful launchers reported no primary, cleanup or post-run errors. Each retained 23 memory samples, all at pressure level 1 with zero reported swap; final owned-path process inventories were empty and local SSH clients were reaped. These observations do not prove remote `waitpid`. Bounded read-only retrieval retained all two solo and four rank sidecars, checked exact bytes and stable file descriptors, and correlated their saved request identities.

The source correlation checked all 327 archived file hashes and matched 22 owner-related source files to the frozen proposals; the two successful invocations share the same source manifest and native pin. This is narrower than a complete runtime-provenance audit or an independent binary rebuild. Callback placement, clock origin and outer-success publication remain assertions supported by the saved source. The native build passed in 70.27 s with 35 adapter records; standalone collector/output checks passed six traces, 90 rejected calls and 11 publication cases.

The failed first solo cohort remains rejected: native exit was zero, but the parent detected documentation source drift after execution. A fresh second cohort passed. Its first sidecar retrieval also remains failed: the v1 reader incorrectly expected the solo bundle directly under the run directory and rejected before SSH or sidecar access. V2 pinned the actual frozen path constructor, required the bundle inside the solo native directory, and added a regression rejecting the old layout. Neither failure was relabelled successful.

The owner auditor froze before its authors' first owner-candidate access, but after the successful solo invocation had begun; it preceded the rank invocation. The readers froze before their authors' respective candidate-sidecar access, after native execution began. Existing numerical oracles preceded execution. The checks were fixed before candidate inspection; some new helpers were completed after execution began.

SHA-256 pins identify the retained evidence without publishing private run locations or prompt contents. Each timing execution receipt binds its numerical audit, retrieval, raw sidecar hashes and source correlation.

| Evidence | SHA-256 |
| --- | --- |
| Shared native executable | `963a1db39865266a1a0f5c20b9404435a4243d131957dbbbd1e157fe7ca1c0c5` |
| Shared source manifest | `ffa4eb9d79629dc2323e4fcf22cc01f840fe8a868913e14cd9242a39a135e499` |
| Frozen owner auditor manifest | `01564e53ceb50ac482245f13f2b068c90b90ec8977815638e701fe82cd5e30e8` |
| Passed solo launcher | `a9a26682d86a98bfde82981e34c725e822e15c693cc4dbe02542bd1324127048` |
| Solo timing audit execution | `9cee5ae917d740daeddbd26e8255634089fab2b04023f72cfb925ce9c49a15f5` |
| Passed rank launcher | `fc012d9ca03d3bdb5e56468805fdd60c52c18638dd119c728281518542e82ba7` |
| Rank timing audit execution | `6007828bd4cbfed6869adef9c2f870c922d9802720fb6230b0891fd539ecb7bc` |
| Retained rejected first solo launcher | `1f7d5219ef67cbb61274979ab73f867a45fc824dd56c589cddf91db300402858` |
| Retained failed v1 retrieval | `32024df914f02cb3f47a1aa1d9796407a77618178496a6fdc1f3236abddc588a` |

Source: [owner markers](Sources/ClusterInference/Tracing/CBv2OwnerPhaseObservation.swift), [recorder](Sources/ClusterInference/Tracing/QwenPrefillOwnerRecorder.swift), [selected-frame binding](Sources/ClusterInference/Tracing/QwenPrefillOwnerFrameBinding.swift), and [joint outer-success publication](Sources/ClusterInference/Tracing/QwenPrefillTraceCaptures.swift).
