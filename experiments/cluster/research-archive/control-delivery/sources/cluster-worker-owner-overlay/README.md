# Swift native-worker owner adapter

This private overlay implements an owned duplex pipe channel, a two-worker request coordinator and a concrete `DistributedResidentExecutionOwner` / `DistributedResidentRequestLease` adapter. It uses the frozen `DarkbloomClusterProtocol` values and parser. Product startup uses a directly launched Swift executable with explicit arguments and environment; there is no shell, Python or SSH in this path.

The coordinator currently controls **two local direct children on one Mac**. It is useful for CPU control-path qualification and supplies the local worker primitive for the eventual distributed owner. It is not an authenticated remote endpoint, does not start a worker on another Mac, and does not establish remote process fencing. Native workers must not spawn untracked descendants. A complete live backend still needs the native worker executable, package integration, authenticated remote-owner control, and end-to-end model qualification.

## Files and integration

| File | Responsibility |
| --- | --- |
| `Sources/DarkbloomClusterProcess/ClusterWorkerProcess.swift` | Foundation `Process`, explicit launch environment, bounded Darwin `poll`/read/write, strict event epoch/sequence, startup/lifetime enforcement and actual child exit observation. |
| `Sources/DarkbloomClusterProcess/ClusterWorkerPair.swift` | Ordered ranks with matching identity/profile/plan, joint named-byte accounting, one active request, failure quarantine and shutdown. |
| `Sources/DarkbloomClusterProcess/ClusterWorkerRequest.swift` | Reserve/start separation, committed-token decisions, clean finish versus cancellation, both local retirement acknowledgments or independently observed process fences. |
| `proposed/provider-swift/Sources/ProviderCore/Inference/Distributed/DistributedPipeExecutionOwner.swift` | Concrete conformance to the existing provider owner/lease contracts, using values only. |

Add a Foundation-only `DarkbloomClusterProcess` library target depending on `DarkbloomClusterProtocol`. The proposed provider file belongs in the existing ProviderCore distributed directory and depends on those two library products, not on the native runtime. Both new modules compile with a macOS 14 deployment target. No package manifest, default engine factory or main-repository file is changed here.

`BoundedProcess.swift` was inspected first. It is a one-shot helper with private wait/fence methods, so it cannot own a resident duplex stream unchanged. This channel retains its terminate → grace → kill → observed exit approach, and drains bounded diagnostics concurrently. It does not broaden or alter that existing helper.

Construct each `ClusterWorkerProcess` with an explicit executable URL, arguments, complete environment, expected identity/rank/profile/plan, startup deadline and hard lifetime deadline. Call `launch()`, then initialize `ClusterWorkerPair(workers:startupDeadline:)` with ranks `[0, 1]`. Construct `DistributedPipeExecutionOwner(pair:profile:chunkSize:)` and inject it through the existing opt-in distributed factory. Caller ownership remains explicit on construction failure; no automatic product registration is added.

The native facade's worker entry is being assembled separately around `QwenResidentRuntime`. Its agreed startup surface is exactly twelve flag/value pairs: model directory, rank, stage cut, membership epoch, model ID, artifact/configuration hashes, ordered peer IDs/build hashes and deadline uptime nanoseconds. The parent launch bounds accept that surface. JACCL/arithmetic settings remain explicit environment entries. Its registered profile is `registered_qwen35_9b_greedy_generation_v1`, with 8192 prompt, 512 chunk and 128 output limits, at most 16 lifetime requests and a process deadline of at most 300 seconds. Supply that same hard local lifetime to this channel; do not silently extend it.

## Ownership and resource accounting

Local readiness fields remain backend assertions. The parent matches both identities, ordered ranks, profiles and plan fingerprints; it does not perform artifact attestation or duplicate native resource sampling.

Each local ready record advertises a named request allowance. The pair advertises their checked sum, **not a sum of physical RAM**. Reservation is sequential: rank 0 receives its local ceiling capped by the remaining provider budget, then rank 1 receives its own ceiling capped by the remaining budget after rank 0's actual admission. The lease charges the sum of admitted bytes. An asymmetric stage is never forced into the smaller rank's allowance. The parent does not reproduce native tensor-ledger formulas; each native owner checks its actual resources before admitting. No forward starts until both ranks are admitted.

`reserve` creates a fresh native UUID even when the public CBv2 ID is reused after retirement. The raw prompt and sorted stop IDs, output/chunk counts and local deadline are bounded by the protocol and resident profile. Unsupported sampling, multimodal/position payloads, constraints, logprobs, priority or cache donation are rejected. Stop strings remain in provider detokenization; the worker only receives stop token IDs. No prefix cache state is shared or donated.

If admission partially succeeds and then fails, the pair becomes unavailable. The original error is rethrown only after the private reservation has actual cleanup acknowledgments or owner-observed child exits and has been released. Internal cleanup and fencing continue on independent queues while the reserving caller waits. If the OS cannot terminate a child, ownership stays retained and that failure return stays pending; elapsed time cannot satisfy the provider's no-reservation-on-throw contract.

`start` returns after scheduling the executor. Rank 0 publishes each committed token to the provider and waits for its exact decision before another forward. `false` means clean stop unless the callback called `cancel()`. EOS has priority over output-limit completion, then client stop. Both workers must produce the same clean finish and local `retired(clean)` before clean lease completion. Rank 1 never needs a synthetic token replay.

Abnormal cancellation permanently invalidates this pair. The cancellation watchdog is armed before any provider callback; failure callbacks cannot suppress it. Process and pair invalidation notifications are one-shot and asynchronous, after fault/cancellation state changes, and never run on the pipe pump. A stalled token callback, failed callback or invalidation handler therefore cannot prevent process fencing.

Cleanup may accept an already in-flight local retirement acknowledgment for the exact request while preserving cancellation as the primary outcome. It never turns a clean callback stop into cancellation or erases a prior error. No acknowledgment is inferred from EOF, a sent signal, a sent cancel, a timeout or a terminal token event. `waitUntilRetired` completes only after both required local acknowledgments or independently observed direct-child exits; `releaseResources` is effective once and only afterward.

## Bounds and deadlines

Command and event record limits come from the frozen protocol. Reads/writes are at most 64 KiB, queued commands at most 16 records / 1 MiB, and queued events at most 32 records. Stderr is continuously drained with a 1 MiB lifetime ceiling and 64 KiB retained tail. Excess/malformed output invalidates the worker. The owner never holds a lock across a user callback or a blocking native operation.

All uptime values are local to the execution Mac. Startup, command writes, request admission/execution and hard process lifetime are charged against monotonic time. Request deadlines cannot extend beyond either worker's explicit lifetime. The pump checks at most 50 ms apart; deadline expiry starts termination, and SIGKILL follows a two-second grace if the child remains alive. A sent SIGKILL is not an observed exit. Foundation's exit observation and `waitUntilExit` establish direct-child completion; the code does not claim a finite successful reap if the OS will not complete termination. Final pipe drain is capped at one second after observed child exit.

`projectFirstToken` returns `.unbounded`: there is no measured transfer/control envelope in this adapter. Named reservation bytes are retained conservatively as bytes in use until release. They are not a GPU peak or whole-process memory measurement.

## CPU qualification

Run `bash Tests/run.sh`. The runner separately compiles/imports both public modules with Swift 6, warnings as errors and macOS 14 targets. It launches a small Swift fake worker directly, without model/GPU/MLX execution. Ten groups cover reuse, clean stop/EOS, pre-start and callback cancellation, peer exit, malformed/partial output, stderr caps, ignored termination, blocked callbacks, partial admission, asymmetric budgets and independent process lifetime. Tests require actual direct-child exit observation after shutdown/fencing.

A second executable compiles the **unchanged actual ProviderCore owner/lease contract source** together with the proposed adapter. Test-only MLXLMCommon value stand-ins avoid linking/loading MLX; they are not production files and do not qualify a full ProviderCore build. It checks unknown first-token cost, unsupported-request refusal, both admissions and actual token/finish mapping, release, shutdown and a fresh native UUID when a public CBv2 ID is reused. A real ProviderCore build and native worker/model end-to-end run remain pending.

Earlier compiler/fixture/deadline failures remain in the private output files. The final checks include the discovered idle lifetime/subtraction race and the root review's blocked-failure and invalidation-callback corrections; no prior failed output is relabeled as passing.
