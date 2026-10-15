# Offline prompt makespan model

2026-09-14. Source-only design for the current long-prefill protocol; no candidate stdout, phase arrays, model payloads, native execution, compiler, or SSH was used. Exact source bytes are listed in `source-pins.json`. This note recommends a pure evaluator, not a new runtime or admission policy.

Use a **receive-credit fork followed by a consumed-credit join**. The current one-chunk lookahead is substantially narrower than an ordinary two-stage streaming pipeline: it overlaps the next producer preparation with current consumer execution, but does not send the next header or payload during that consumption. A collapsed rendezvous cost model can shortlist candidates while preserving this restriction. Its predictions are conditional estimates, not exact trace replay or measured latency.

## Source constraints

1. The producer commits preparation of chunk `k`, constructs and validates its envelope, sends header and payload, and receives the validated **received** ACK. Its original boundary wrapper is then released. Only now may lookahead prepare `k+1`. Serial mode skips that preparation until the current consumed ACK is drained. [Sender, lines 28–78; transport sender, lines 8–95.]
2. The receiver validates an owned, evaluated payload before sending the received ACK. It then consumes `k`, validates its commit, selects the token on the final chunk, releases the original received wrapper, and sends **consumed**. The next header cannot begin until the producer has drained this ACK and the receiver's ACK send has completed. [Transport receiver, lines 20–64; rank receiver, lines 27–47.]
3. Lookahead holds at most one prepared native boundary and one CPU pending-consumed ticket. While preparing `k+1`, the producer may have committed two chunks beyond completed transport credit. There is still only one outstanding boundary transaction; two committed frontiers do not grant two send credits. Wrapper release does not prove absence of storage aliases. [Sender; transport state; rank trace/result.]
4. Native transport operations are synchronous and non-reentrant. A process cannot execute its model while its own transport operation is active. Completed P2P calls evaluate the communication operation, synchronize its CPU stream, then synchronize the GPU stream. Their elapsed time therefore includes staging/fences/backend waits, not just link service. [Transport, lines 4–8; CollectivePointToPoint, lines 103–110.]
5. Two process IDs are not evidence of two physical accelerators. **Exclude same-GPU placements from the independent-device lookahead formula.** Existing one-GPU serial/lookahead traces cannot establish independent accelerator service costs. Supporting a shared device later requires an explicit resource schedule and contention measurements; assigning two ranks two synthetic device IDs is invalid.

Current native long admission is the registered 9B, 8,192 prompt tokens, chunks of 512, output count one, sixteen chunks, and a selected contiguous two-stage Plan. The BF16 residual is `[1,512,4096]`, or 4,194,304 bytes, regardless of that Plan's cut. These are adapter facts; the evaluator should accept validated chunk geometry and opaque Plan/stage identities rather than hardcode this model or recreate its fingerprint.

## Smallest useful cost contract

Use integer nanoseconds; reject booleans, negatives, inconsistent vector lengths, and overflow in a bounded interchange format. A missing cost is `null`/unknown, never zero. Each cost set has an explicit measurement-boundary version and provenance. Per chunk:

| Symbol | Exclusive modeled scope |
| --- | --- |
| `P[k]` | Producer preparation through its validated native commit and produced-boundary hashing. |
| `C[k]` | Receiver consumption and commit validation; includes its incoming-boundary checks. Final `C` also includes final norm/head/logits work and finite selection. |
| `H[k]` | Post-prepare pre-header copy/hash/encoding, header/ready exchange, payload transfer and receive-side pre-consumption validation, received ACK, and producer wrapper release, collapsed to a common receive-credit point. |
| `D[k]` | Post-branch receiver wrapper release, consumed ACK/drain, and required frame bookkeeping, collapsed to a common next-frame-credit point. |
| `S`, `T` | Collapsed startup and final selected-token return/validation tails, with stated boundaries. |

`H` and `D` require calibrated joint endpoint contracts. They are not the sum of overlapping sender/receiver wall spans. Nor is `H` simply `payload_bytes / bandwidth`: there are separate length/header transfers, ready/received/consumed ACKs, hashing/copies, and native completion fences. One observed blocking span must not be charged both as service and as dependency wait.

The two received-credit endpoints are not simultaneous in the implementation; the consumer can already be starting while the producer releases its wrapper. Similarly a consumed-ACK send can already be waiting while preparation-ahead runs. Collapsing these to common points is an explicit approximation. It is not a proven upper bound without additional cost assumptions.

## Exact recurrence for that approximation

For `N >= 1`, with independent physical devices, fixed measured/modeled service vectors, and disjoint scope accounting:

```text
serial = S + sum(P[k] + H[k] + C[k] + D[k], k=0..N-1) + T

lookahead = S + P[0]
for k = 0..N-2:
    lookahead += H[k] + max(C[k], P[k+1]) + D[k]
lookahead += H[N-1] + C[N-1] + D[N-1] + T
```

There is no preparation after the final chunk. The final consumed ACK precedes the returned-token stop event. The final consumer cost differs from earlier chunks: earlier consumers return an evaluation handle, whereas the final consumer computes the narrowed vocabulary row and selects the token. Do not add the head or selection again in `T`.

For the same vectors and tails, the modeled serial-minus-lookahead saving is exactly `sum(min(C[k], P[k+1]), k=0..N-2)`. `N=1` gives equality. These are useful evaluator tests, not hardware speedup promises. Explicitly setting overheads to zero gives a separate idealized screening scenario under fixed service costs; it must never fill missing measurements in a measured scenario.

Startup has one source-specific wrinkle: there is no barrier after both fresh contexts are created. Rank 0 may prepare chunk zero while rank 1 is still creating its context. The scalar `S` deliberately collapses this. An optional precise dependency refinement uses modeled producer/consumer ready offsets `s0`, `s1`: initialize `t = max(s0 + P[0], s1)`, add `H[k] + max(C[k], P[k+1]) + D[k]` for lookahead nonfinal chunks (or `H[k]+C[k]+D[k]+P[k+1]` for serial), then add the final `H+C+D+T`. These offsets require a common modeled origin; never derive them by subtracting separate process clocks.

Full solo uses separately measured full-model chunk costs: `S_solo + sum(F[k]) + selection_solo + wrapper_tail`. Final `F` includes the final head/row; selection is separate in its source. Solo has no residual handoff or returned-token packet. A sequential pair in one process is a different execution mode with an owned-copy boundary and is not represented by the interprocess serial formula. Layer count ratios cannot supply missing `P`, `C`, or `F`.

## What existing reports actually measure

| Existing evidence | Usable quantity and limit |
| --- | --- |
| Rank-zero `timing.elapsedNanoseconds` | One local end-to-end diagnostic: before start send/fresh contexts through final consumed plus received-token validation. Includes scalar tracing, fresh-state admission, copies and final selection/return. Excludes readiness, model load, token distribution, final diagnostic capture, post-stop ACK and retirement. This is the validation objective. Rank one has no equivalent timer. |
| Rank `actions` | Ordered commits, frame IDs, and slot/credit counts. They have no timestamps without the optional phase sidecar. |
| Optional phase sidecar | Local monotone CPU elapsed spans. `prepare.begin → prepare.committed` approximates `P`; `receive.beginConsumption → consumptionAndSelectionValidated` approximates `C`. Both include checks and observer overhead; neither is isolated GPU time. |
| Transport phase spans | Local header/payload/ACK intervals including peer waits and fences. Useful for diagnosing a run; insufficient alone to separate intrinsic link/staging service from wait. |
| Solo timer and phases | Comparable fresh-state-through-selection objective, local per-chunk spans and separate selection span. Phase markers enclose, rather than exactly equal, the primary timer boundaries. |
| Selected-owner sidecar | Only chunk seven, four pairs for graph construction, root staging, evaluation, validation/commit. CPU timings include hooks/checks; no GPU-kernel assertion, layer timing series, or all-chunk coverage. Gaps and outer validation/hashing prevent treating their sum as the entire chunk cost. |
| P2P correctness fixture | Exact bytes/frames/control results, with no timing fields and explicit `physicalTransferQualified=false`. It is not a bandwidth calibration. |

There is no `makeEnvelope.begin` phase marker: the sender's extra copy/hash occurs before `send.beginHeader`. In serial, the preceding prepare-commit gap brackets this plus wrapper/check work. For lookahead chunks after the first, `prepare.committed → beginHeader` also includes the previous consumed drain; it is not a staging cost. New explicit staging markers or a separate bounded calibration are needed for a clean reusable estimate.

No sidecar asserts cross-process clock alignment, GPU overlap, or model release. Join its exact bytes to the successful parent, numerical/source qualification, stdout, Plan/stage identities, and actual placement. Do not infer those joins from phase identity alone, or infer overlap by summing/subtracting rank timestamps.

## Measurement and implementation boundary

Measure per-chunk preparation/consumption on their actual selected stages and full-solo costs on the full model, with the same precision, history, prefix length, residency and observer configuration. Preserve chunk zero's lazy/first-use behavior and the final head cost. Distinct-device measurements need their own qualification; one-GPU rank measurements carry shared-device contention. Repeated joint trials or held-out end-to-end timers test whether independently calibrated costs transfer to concurrent execution.

Measure residual CPU copy/hash/encoding and control/payload paths separately when endpoint scopes can be isolated; otherwise retain one explicitly jointly calibrated `H`/`D` contract. Record byte counts, dtype, contiguous ownership, backend, endpoints and fence policy. Host/network measurements that omit the existing MLX completion or validation contract cannot silently replace it.

The first public evaluator needs only closed policies `solo`, `serial_v1`, and `prompt_lookahead_one_v1`, fixed vectors/tails, physical resource IDs, and cost provenance. Return an estimate with assumptions, `missing_measurements`, or `unsupported_resource_overlap`; preserve external eligibility as an independent supplied result. A generic optimizer, Plan serializer, runtime launcher, or task scheduler is unnecessary. Root owns implementation and fixtures.

Keep memory eligibility separate from timing: actual stage weights/state, allocator bounds/cache, the prepared-next and received-current residuals, host staging, lazy inert buffers, and operational reserves must fit their real devices under existing live guards. The named long tensor budget explicitly excludes whole-process weights/workspaces; the one-boundary credit invariant is not a full memory bound. Scheduling estimates cannot grant a load/forward permit.

Store source/artifact/config/Plan/stage/storage/runtime identities; chunk offset/count/final flag; prompt/history pin; physical device/link identity; cold/warm status; measurement boundaries; observation settings; and exact evidence hashes alongside cost vectors. Retain measured, modeled, and idealized status separately. Report per-run scenario estimates or justified uncertainty; summing per-phase medians does not produce an end-to-end median. No throughput or fastest-cut claim follows from this note.

## Source index

Paths below are relative to `experiments/cluster/inference/Sources/ClusterInference`; `source-pins.json` contains SHA-256 and byte count for each source.

- Protocol/credit: `QwenLongPrefillRankSender.swift`, `QwenLongPrefillRankReceiver.swift`, `QwenLayerStageProfiledPrefillTransport{,Sender,Receiver,State,Control,Types}.swift`.
- Execution/fences: `QwenLayerStageProfiledPrefillNativeIO.swift`, `CollectivePointToPoint.swift`, `QwenLayerStageProfiledPrefillComputeContext.swift`, `QwenLayerStageSession.swift`, `QwenLayerStageBoundary.swift`.
- Clock/objective: `QwenLongPrefillRankRequest.swift`, `QwenLongPrefillRankResult.swift`, `QwenLongPrefillRankReport.swift`, `QwenLongPrefillRankTrace.swift`, `QwenLongPrefillSoloRequest.swift`, `CBv2RequestSession.swift`.
- Optional observations: `Tracing/QwenPrefillPhase{Types,Recorder}.swift`, `Tracing/QwenPrefillOwnerTypes.swift`, `Tracing/CBv2OwnerPhaseObservation.swift`.
- Geometry/resource limits: `QwenLayerStageProfiledComputeAdmission.swift`, `QwenLongPrefillTensorBudget.swift`, `QwenRegistered9BLongPrefillAdmission.swift`.
- Transfer qualification scope: `StagePointToPointCheck.swift`, `StagePointToPointControlCheck.swift`, `StagePointToPointFixture.swift`.
