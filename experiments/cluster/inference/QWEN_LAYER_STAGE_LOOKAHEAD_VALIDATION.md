# Registered 9B prompt lookahead across two stage processes

*Last updated: 2026-09-14*

The registered dense Qwen3.5 9B checkpoint completed the same recorded request
with one prompt chunk of producer lookahead. Independent CPU replay confirmed
exact baseline state and native BF16 logits, and checked the complete recorded
host action order. This is a correctness and scheduling result on two local
processes sharing one Mac. It does not measure simultaneous GPU execution,
cluster throughput, Thunderbolt or RDMA performance.

The [serialized stage result](QWEN_LAYER_STAGE_RANK_VALIDATION.md) and
[full-model baseline](QWEN_LAYER_STAGE_REAL_VALIDATION.md) fix the comparison
artifact, arithmetic and input history. Existing captured modes remain
diagnostics with `throughputMeasurementValid: false`.

## Protocol and ownership

`qwen-layer-stage-lookahead-check` uses the existing bounded real-stage
admission: native CBv2, an explicitly pinned artifact, actual token files,
fresh cohort epoch, two loopback ranks, prompt at most 128, chunks at most 32,
at most four output rows and a deadline at most 180 seconds. Multiple outputs
require an immutable teacher history; generated-token feedback is not present.

Version 2 wraps the unchanged strict boundary header in the explicit flow
`prompt_lookahead_one_v1`. Bare version 1 and incompatible flows are rejected.
Each acknowledgement binds its own phase and the exact encoded outer envelope.
The wire decoder checks raw duplicate keys and integer lexemes before parsing
can normalize them, and derives payload shape and byte limits locally.

```mermaid
sequenceDiagram
    participant P as Producer stage
    participant C as Consumer stage
    P->>C: Validated envelope A
    C->>P: Ready ACK A
    P->>C: Native residual A
    C->>P: Received ACK A after byte validation
    par Separate process work permitted
        P->>P: Release source A; prepare next prompt chunk B
    and
        C->>C: Consume A; commit state; capture evidence; release input
    end
    C->>P: Consumed ACK A
    P->>P: Validate A completion using saved CPU capture
    P->>C: Next envelope B
```

The diagram describes permitted scheduling. Each process has one serialized
MLX owner; the host trace does not establish overlapping execution on the GPU.
The sender releases the original transmitted array wrapper before preparing
the next prompt chunk. Its pending ticket and old frame capture contain only
CPU data, so an acknowledgement for A is checked against A even when the live
producer frontier has advanced through B. Before another header, A's consumed
acknowledgement must be drained. Decode preparation remains serialized, and the
final frame always drains its consumed acknowledgement before close.

The pure sender bounds produced-minus-received and received-minus-completed
to one each; produced-minus-completed can reach two. The receiver owns at most
one residual. Native weak-reference checks verify release of original array
wrappers; they do not prove absence of all native aliases or bound total
allocator memory. Any forward, capture, transport, callback or close failure
retires local state and transport, and the parent cancels the whole cohort.

## Observed result

| Item | Observed value |
| --- | --- |
| Input | Same 65-token prompt prefix and three teacher tokens as the baseline |
| Stage placement | Layers 0–15 and 16–31; unchanged full projection widths |
| Committed frontiers | 32, 64, 65, 66, 67 and 68 |
| State comparison | All 432 complete component metadata/digest entries exact |
| Logit comparison | Four × 248,320 values; 1,986,560 native BF16 bytes exact per side |
| Completed native frames | Six per rank |
| Host action records | 73 sender; 85 receiver; every scalar and ticket checked |
| Prompt preparations before prior consumed drain | Two |
| Sender queue maxima | Produced-minus-received 1; received-minus-completed 1; total gap 2 |
| Explicit boundary slots | At most one per rank |
| Original array wrapper releases | Six per rank, asserted before the next permitted phase |
| Process outcome | Both exited 0; final acknowledgements drained; requests and models retired |

The numerical oracle reuses the frozen serialized-stage comparison for source,
request, state and logits. It independently reconstructs the actual version 2
envelopes and phase-specific acknowledgement identities before adapting only
transport metadata for that older oracle. Original captures and historical
records are preserved. It derives the expected action order directly from the
admitted prompt/teacher timeline and compares every recorded field, including
which older ticket completes after the producer has advanced.

The outputs include full finite logit values, reconstructed to native bytes
with signed zero preserved. State arrays are represented by metadata and
digests. Neither raw boundary arrays, raw envelope bytes nor actual ACK arrays
are exported; native ownership/hash/phase checks and source-bound traces remain
part of that evidence. No internal baseline cutpoint residual was captured.

## Resources and failed first attempt

The first attempt was stopped by the unchanged memory guard after reported swap
use increased by 118 MiB. Both supervisors exited 143 and were reaped; a separate
process inventory found no owned worker remaining. That run produced ready
records only and is preserved as a resource-aborted attempt, not a correctness
pass.

After cleanup, actual free memory rose from about 1.57 GB before the first run
to 7.45 GB. An additional screen before archive/artifact preparation required
at least 6 GiB of actual free memory. At the launcher's later preflight, actual
free memory was 3,379,560,448 bytes; the earlier screen does not establish free
memory throughout launch. The existing reclaimable-memory gate still applied.
The retry retained the same
binary, request, source and no-new-swap guard. No unrelated application was
stopped. All 13 retry observations stayed at pressure level 2 with unchanged
reported swap use.

Native MLX active-memory peaks were 2,700,848,602 and 2,701,118,800 bytes per
rank. After model release and cache clearing, active memory was 2,016 and 2,008
bytes, with zero cached bytes. The process observer began before launch and
sampled a maximum combined native RSS of 5,150,015,488 bytes. That sampled sum
can miss the actual process peak and is distinct from either MLX peak. A final
independent process inventory found no owned worker remaining.

## Code and remaining work

| Concern | Implementation |
| --- | --- |
| Real input admission and thin coordinator | `QwenLayerStageLookaheadAdmission.swift`, `QwenLayerStageLookaheadCheck.swift` |
| Strict envelope and phase identity | `QwenLayerStageLookaheadWireEnvelope.swift`, `QwenLayerStageLookaheadWireAcknowledgement.swift` |
| Pure bounded scheduling | `QwenLayerStageOverlapPlan.swift`, `QwenLayerStageOverlapSender.swift`, `QwenLayerStageOverlapReceiver.swift` |
| Completed native transfer and release scopes | `QwenLayerStageLookaheadTransport.swift` |
| Native stage state and observation | `QwenLayerStageLookaheadContext.swift` |
| Sender/receiver ownership and retirement | `QwenLayerStageLookaheadRequest.swift`, `QwenLayerStageLookaheadSenderDriver.swift`, `QwenLayerStageLookaheadReceiverDriver.swift` |
| Bounded CPU trace and completion records | `QwenLayerStageLookaheadRequestResult.swift`, `QwenLayerStageLookaheadDriverSupport.swift` |

The native adapter checks passed all 19 records, including 23 new CLI rejection
cases, 21 accepted version 2 envelope cases, 70 wire rejections and four complete
pure schedules with 23 rejected transitions. Previous version 1 checks remain
passing. The frozen successful run archives 173 source files and unchanged
binary resources, input history and model configuration.

The independent comparison passed 28 CPU tests, including coherent token,
header, counter, release-order, state-digest and logit tampering. The archive
audit also verifies the baseline's 194 saved source files. Common model,
loader, state and arithmetic sources remain byte-identical; entry-point and
transport additions are recorded separately.

| Frozen item | SHA-256 |
| --- | --- |
| Native executable | `4cb6a17d507dbab076d83a73708373e02cc16be9f244ade251ae63cbc60f81a2` |
| Successful retry launcher receipt | `2979510c083f23963cedabce62cec962d65543d316c02c9e016491813bff7cdb` |
| Independent comparison implementation | `821e5199032d2721d8598232502a5acd29b3c10253634c8f6a991be9949ce76e` |
| Complete independent archive/action/numerical audit | `697b5656207dfe3decbd75897bc213389119eca9b0c943ff50b14e5a9a727b43` |
| Independent 28-test receipt | `528ff2d8d0bb49cf89be0f48c20cbc0b3b12a0aea42b4c65e95b3a662739f474` |
| Successful process/resource postflight | `ba28e45694e701cf03834cca33750e33a7f0bf91b3b82fc9356c71b8109d7464` |
| Original resource-aborted launcher receipt | `fe29bb8fa222e54f88a850b449eef928e64d7c58a2e3737c91e488557bc5807e` |

Useful throughput measurements require a separate path without per-frame state
snapshots or full-vocabulary JSON capture, checked target-token return, fair
solo controls, longer-context admission and physical peers. The target
27B/two-M3-Ultra workload remains unqualified.
