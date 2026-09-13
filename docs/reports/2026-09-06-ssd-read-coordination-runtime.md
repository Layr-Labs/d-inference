# SSD read coordination builds and passes bounded validation

> Last updated: 2026-09-06 · commit `35fea6d0e`

The same-file SSD checkpoint read-coordination candidate builds both release products on M5 and passes **30 fresh provider/CLI suites: 270 functions, 324 expanded cases, no skips or failures**. This record banks source, build, CPU-regression and synthetic test evidence only. The subsequent [Qwen3.8 B2 retest](2026-09-06-qwen38-b2-coordinated-reads.md) is reported separately; these build results alone establish no model, performance or release acceptance.

## Coordination change and final alias repair

Two reads of the same valid checkpoint could interfere through recency updates. The deterministic CPU reproducer sets the same `mtime` again, which still changes `ctime` while the other read authenticates. The existing file-identity check correctly refuses that changed snapshot. The fix coordinates the reads rather than weakening authentication.

`provider-swift/Sources/ProviderCore/KVCacheSSD/SSDCheckpointFileCoordinator.swift` (`SSDCheckpointFileCoordinator.shared`, `Access.acquire`, `Access.release`) supplies a process-shared, per-path FIFO. `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDHybridCheckpointStore+Read.swift` (`stage`) acquires access before reading the checkpoint and holds it through recency mutation, authentication and unwind. Store instances accessing the same canonical path share the queue; unrelated files do not.

Review found that filesystem-existence-dependent path normalization could give the same checkpoint different coordination keys before and after publication. The final `coordinationPath` expands the known `/tmp` and `/var` aliases during lexical traversal, **before** processing parent components, without consulting whether the target exists. Tests cover absent-to-created and deleted targets, accepted-root aliases, parent traversal, component boundaries and unrelated paths. The bank retains the failing alias reproduction, its passing successor and the final root CPU run; the earlier failure is not relabelled as a successful run.

**Tradeoff:** same-file staging I/O queues instead of overlapping. This is not a model-wide or inference-wide lock, and it is not a cross-process filesystem lock. Queued stages retain their already-reserved scratch budget until cancellation or completion; the tests check refunds, but this record does not establish the real-model latency or throughput cost.

## Preserved checks and lifecycle

| Contract | Code and bounded evidence |
| --- | --- |
| Authentication remains strict | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDAuthenticatedFileIdentity.swift` (`SSDAuthenticatedFileIdentity`, `matches`) is unchanged: Git blob `36767824b5f17bd3cee82926f2f59c1b440817fc`. Replacement and corrupt-ciphertext tests still reject invalid reads. |
| Cancellation does not unlock an active read prematurely | `SSDCheckpointFileCoordinator.Access.acquire` and `release` retain ownership until unwind; queued cancellation removes only that waiter. FIFO, handoff races and independent-file progress are exercised. |
| TTL and epoch are rechecked after waiting | `SSDHybridCheckpointStore.stage` checks cancellation/epoch and `freshFileBytes` after acquiring access, before I/O; installation checks cancellation again. Queued-expiry and epoch-change tests perform no read. |
| Close and request replacement cannot strand activity | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDHybridCheckpointStore.swift` (`completeStaging`, `abandonStaging`, `close`) cancels queued accesses. Object-identity checks protect successor requests; accepted activity begins under the store lock, and release/scratch cleanup precede activity drain. |
| Staging budgets and recency remain accounted | Coordinated staging tests cover provider and process-owned destinations, cancellation/close refunds and zero outstanding reservations. The synthetic clock/reopen test retains sliding TTL without changing ciphertext or epoch, then expires the entry; it is not persistent-key restart validation. |

Only the coordinator, checkpoint read/store plumbing and six test/support files change in the provider portion of this source delta. The [Qwen-first backend policy and rollback contract](2026-09-06-qwen-first-candidate-runtime.md) are not changed by this repair.

## Exact source, build and test scope

| Property | Verified evidence |
| --- | --- |
| Parent source | `35fea6d0e3b05ff65d60d9675ab480159913ac62` |
| Native source | `f2d79145e040bbc28c6e0e355a19bc8923a70434`, unchanged |
| Original CPU regression | 3 suites; 11 functions / 14 expanded cases. The small CPU harness and exact source-link inventory are retained; its `MLXLMCommon` stub is not native MLX execution. |
| Fresh M5 provider/CLI tests | 30 suites; 270 functions / 324 cases. New coverage includes path aliases, FIFO/cancellation, overlapping authentication, cross-store coordination, TTL/epoch revalidation, recency and staging refunds. |
| Inherited native/compiler tests | 27 functions / 29 cases, separately source-bound to the unchanged native implementation and final fixture; not rerun or counted as fresh provider coverage. |
| Owned command groups | All 41 report exit zero and complete process-group cleanup; collected final observation contains no owned or unexpected workers. |
| Independent artifact audit | Ten audit groups pass: 7,436 tracked files, 13 symlink references, signed source commits, actual product closures containing the new coordinator, exact dependency locks and all eight artifact hashes. |
| Signing boundary | Strict static verification of ad-hoc executable signatures only; no Developer ID or notarization claim. |

Both the provider and radix benchmark use canonical locked SwiftPM release builds. The provider executable SHA-256 is `e18c11b3429c06156fd2d85e4ddb9334053f635087438733a5852ba31bb743b7`; radix is `f39e5f21db20f9fcc459222ecca9068f08fa90642c151f2e31bd5764b6885d05`. The artifact manifest is `0e25054af04be640d2701cbb5ef5dfb20b8766d48e9bfda7e2f9fe79d9cfc62a`; the bounded runtime-review receipt is `cc36a63b58fdacaedee40cd17dd3ee1368eca378ae44036f9384f7583ed17437`.

## Banked evidence and remaining boundary

The [evidence manifest](evidence/ssd-read-coordination-runtime-2026-09-06/manifest.json) binds the unchanged **158-member metadata capsule**, source/audit/test receipts, CPU logs and alias-review reproduction. Capsule member hashes match the collected audit inputs. Member-type, path, UTF-8/decompressed-graph and secret-pattern checks pass; binaries, binary shaders, weights, checkpoint bodies, key material and model-pilot results are excluded. Pattern scanning is a bounded check, not a guarantee against every possible secret encoding.

The capsule contains the raw 30-suite logs, actual build/source/dependency graphs, lock proofs and 41 terminal/cleanup records. Test outcomes are parsed from terminal records, not the word “failed” inside passing negative-test names. Loose CPU logs use `.txt` while preserving their original bytes, so no ignored `.log` files require forced staging. Absolute paths inside unchanged receipts are historical provenance; active bank paths and archive members are enumerated separately in the manifest.

The inherited native evidence remains in the [forward-width runtime bank](2026-09-06-forward-width-runtime.md), rather than duplicating its capsule. The [preceding failed model run](2026-09-06-qwen38-b2-staging-policy.md) and [fresh successful retest](2026-09-06-qwen38-b2-coordinated-reads.md) retain their own evidence. This build report alone does not establish numerical closure, B2/B4 performance, signed persistence, two-host behavior or release readiness. No host, production, deployment, commit or push action is part of this banking work.
