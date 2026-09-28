# Qwen prefill phase trace: first solo validation

> Last updated: 2026-09-14 · commit `e4df336bc`

One registered Qwen3.5-9B request completed with the optional local phase recorder enabled. The unchanged numerical audit and the new phase correlation audit both passed. This was one fresh full-model process on a 24 GiB Mac: batch one, 8,192 prompt tokens, sixteen 512-token chunks, one selected output token, and no teacher decode, warmup or repeated request. It used the existing BF16 CBv2 [long solo path](QWEN_LONG_PREFILL_SOLO_VALIDATION.md).

The sidecar contains 5,505 exact bytes and 41 events, within the production capacity of 512. Its identity matches the complete recorded prompt/request fingerprint and solo role. The phase audit checked every ordinal, phase, optional frame field and committed frontier, plus monotonic UInt64 timestamps and the main clock's marker bounds. Non-frame events omit the frame field.

The main clock starts before fresh request-state construction and stops after finite argmax and scalar readback. Model loading and readiness precede it; final state/logit capture and retirement follow it. The [recorder contract](QWEN_PREFILL_PHASE_TRACE.md) publishes the sidecar only after the outer model owner succeeds. The existing two-record native stdout schema remains unchanged.

| Recorded local interval | Observed duration |
| --- | ---: |
| Main request clock | 18.601628709 s |
| Sum of sixteen prefill chunk spans | 18.598524833 s |
| Fresh request construction markers | 0.797416 ms |
| Finite selection markers | 2.299084 ms |
| Final diagnostics, after stop | 115.931833 ms |
| Request retirement markers, after stop | 0.136333 ms |

Each chunk span runs from its CPU “prefill.begin” observation through “prefill.committed”; the frame indices below are zero-based.

| Frame | Seconds | Frame | Seconds |
| ---: | ---: | ---: | ---: |
| 0 | 1.168897208 | 8 | 1.162435875 |
| 1 | 1.115610667 | 9 | 1.168648083 |
| 2 | 1.124853083 | 10 | 1.179095875 |
| 3 | 1.126803417 | 11 | 1.184533000 |
| 4 | 1.137575333 | 12 | 1.186828542 |
| 5 | 1.138919125 | 13 | 1.198633125 |
| 6 | 1.148634667 | 14 | 1.199045834 |
| 7 | 1.151779166 | 15 | 1.206231833 |

These spans include observer overhead, CPU checks and commit metadata, existing evaluation/synchronization, and scheduling delay. They are not isolated GPU or kernel timings. Setup and selection markers enclose the separate main timestamps, so the rows are not an exact additive decomposition of that clock. Uncovered time remains unclassified. This single observation does not measure recorder overhead, causal acceleration, cross-rank overlap, physical transfer, or performance of 27B models or M3 Ultra systems.

The unchanged 50-test numerical oracle confirmed sixteen commits and 8,192 tokens. Final metadata and digests match the frozen reference: 72 state components covering 319,946,784 logical bytes and a BF16 logit row of shape [1, 248320], covering 496,640 bytes. The reported finite native selection is token 271, matching the reference's unique maximum. Candidate full-vocabulary values and native logit bytes were not exported; this is metadata/digest comparison, not an independent candidate byte comparison. Eight position-offset components are independently reconstructed; the other 64 numerical state components remain opaque digests.

The launcher passed with two native records, empty stderr, and no primary, cleanup or post-run errors. All 24 saved memory samples report pressure level 1 and zero reported swap. Its final run-path process inventory was empty, and the local SSH client was reaped; these observations are not independent remote waitpid proof. Native MLX observations report a cumulative peak of 6,500,375,576 bytes and, after model release/cache clear, 4,016 active bytes and zero cached bytes. That peak is not a whole-process or combined active-plus-cache peak.

There is no separate postflight or comprehensive provenance audit for this phase run. The launcher rechecked its 317-file source archive, executable bundle, raw input and remote model metadata after execution. The separate bounded, read-only sidecar collector retained exact bytes from the owned regular file, checked stable descriptor metadata, and correlated the saved launcher/stdout identity. Those checks have narrower scope than full provenance replay. Clock origin, callback placement and native cleanup remain assertions supported by the retained executable/source archive, rather than independent profiler or OS lifecycle measurements.

The native build passed in 69.39 seconds; 33 adapter records passed, alongside six accepted and 47 rejected recorder cases and 20 publication/IO cases. The existing numerical oracle was frozen before execution. The new sidecar collector and phase auditor were frozen with 23 and 72 CPU/fake tests respectively before their authors accessed candidate output, but after this native execution had begun. This freeze chronology is part of the evidence limits.

The following SHA-256 pins identify the retained evidence; private run paths and prompt contents are intentionally omitted.

| Evidence | SHA-256 |
| --- | --- |
| Native executable | 1d373d352a3f580043cbd6e20d354d6b1b8085ffc10e07874b5bd7bf9a5425ce |
| Build/check checkpoint | 77098ee041df2a6a8cd812fb5ebfb65e61ae2a8ab1b5ca1adcc9df29eeb9fb68 |
| Source archive manifest | b93dd1d94a6cb99fa2d5fdc69eb900182b6c2676b8e9a2f4e9dd7fefc9ae2f48 |
| Launcher receipt | c803dcb49f24d361f23e037b2084f1c7de6095868c1c435c2868660762769742 |
| Numerical audit | 6e5616825b4ce3f637193e60f4bddde582582c33de16d9c25f9a9623e8b0593f |
| Numerical audit execution receipt | f695a261ee9d755c18d840052af4c39cef2109868b4871bb17e3f54ab1ccc5f9 |
| Sidecar collection receipt | 0e3411da0234330738a2bafcbc2e841ded1c641b0bed58b64a38a729281bcb69 |
| Raw phase sidecar | db96ed0144059987d878a8a1c4ed1d18608eb9edc80832a6ac28cb1d1b122f78 |
| Phase correlation audit | 1af25dfeac3df6977d0ddf2b6052d8883f8274ab8983ab66222d82e3b103e9a4 |
| Frozen phase auditor manifest | a540ab7a9ddf115ea3e34712fe152dbcb21d532f03a3e0749b6fd347645e6176 |

Source: [solo request and hook placement](Sources/ClusterInference/QwenLongPrefillSoloRequest.swift), [phase recorder](Sources/ClusterInference/Tracing/QwenPrefillPhaseRecorder.swift), [outer success/publication](Sources/ClusterInference/Tracing/QwenPrefillPhaseCapture.swift), and [bounded sidecar file](Sources/ClusterInference/Tracing/QwenPrefillPhaseFile.swift).
