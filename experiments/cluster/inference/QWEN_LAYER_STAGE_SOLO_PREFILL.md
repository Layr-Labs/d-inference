# Matched-chunk solo prefill reference and timing

> Last updated: 2026-09-14 · commit `e4df336bc`

`qwen-layer-stage-solo-prefill-check` adds a verified full-model control with
the same prompt chunks and final-token selection as the [v3 stage protocol](QWEN_LAYER_STAGE_PREFILL_RANK_PROTOCOL.md).
It is a single-request diagnostic with `throughputMeasurementValid=false`.
**Current status: the guarded registered-9B solo request and independent
final-state/logit-digest audit passed. See the [dated native validation](QWEN_LAYER_STAGE_SOLO_PREFILL_VALIDATION.md)
for the single timing observation and its limits. A public solo launcher is
not available.**

The canonical native build completed in 59.13 seconds with executable SHA-256
`9195a464d9d30784e7becc2c20c487847ef865696abc2d7de1c06ff18c75aaa5`.
The adapter emitted 24 passing records, including the new CLI fixture
(1 accepted / 19 rejected) and reference fixtures (8 accepted / 56 rejected).
These build/parser checks are separate from the dated native validation. The earlier
[14-cohort stage diagnostic](QWEN_LAYER_STAGE_PREFILL_TIMING_DIAGNOSTIC.md) had
no timed solo control and remains unchanged.

## Guarded inputs and reference trust

A private guarded launcher and independently audited reference producer
were used for the dated validation; there is no public solo-launch command. Do not invoke this native
mode directly or treat the public `prefill-ranks` command as a solo launcher.
A reviewed launcher must pin the bundle, artifact, exact prompt and reference,
apply resource gates, own the process deadline and retain cleanup evidence.

Three additional native inputs are mandatory:

| Flag | Meaning |
|---|---|
| `--solo-reference-file PATH` | Retained final-only reference JSON, at most 128 KiB |
| `--solo-reference-sha256 HEX64` | SHA-256 of the exact reference-file bytes |
| `--solo-baseline-evidence-sha256 HEX64` | Independently pinned native baseline evidence fingerprint |

[QwenLayerStageSoloPrefillReference.swift](Sources/ClusterInference/QwenLayerStageSoloPrefillReference.swift)
(`QwenLayerStageSoloPrefillReference.Descriptor`) defines schema 1, kind
`qwen_layer_stage_solo_prefill_reference`. Its fields bind the baseline evidence,
source artifact/configuration/layout/plan and conversion, baseline request
fingerprints, prompt-ID hash and chunk schedule, final state entries/digests,
final logit metadata/digest, and reference selection/token/tie count.
The file contains no model weights, raw state or full vocabulary values.

The reference is **trusted output from an independently audited baseline**.
Its file hash pins bytes; it does not prove who produced them. The native
process cannot rederive the full historical baseline fingerprint from this
final-only descriptor or verify that the producer copied an honest baseline.
The guarded producer must retain and validate the original baseline bytes,
source/provenance, native final row and selection before emitting this DTO.
Both the file pin and baseline evidence pin must come from that verification,
not from an unchecked sidecar supplied alongside the model.

The native decoder rejects duplicate/unknown fields and invalid integer syntax,
checks both explicit pins, then binds the descriptor to the independently
admitted request and loaded model. State geometry, ordered complete component
coverage, byte totals and its metadata fingerprint are checked against the
source configuration; incoming shapes cannot authorize a different allocation.
See [QwenLayerStageSoloPrefillReferenceValidation.swift](Sources/ClusterInference/QwenLayerStageSoloPrefillReferenceValidation.swift)
(`requireRequest`, `validateReferenceState`).

Admission retains the verified dense-Qwen loader limits: 8 GiB declared artifact
payload, 6 GiB canonical tensors and 512 MiB per source tensor, with the existing
named state/boundary budget. It permits 1–128 prompt tokens, chunks 1–32, exactly
one output, no teacher, one repetition and zero warmups. Execution is native
`cbv2-contiguous`, unpartitioned and MTP-free. The reference must match the
actual prompt/chunks and a different request identity. A matched comparison
must use the same schedule on both paths; the initial stage workload is65/32/1.
Transport, epoch, stage policy and stage-logit-dtype options are rejected here.
[QwenLayerStageSoloPrefillCLIAdmission.swift](Sources/ClusterInference/QwenLayerStageSoloPrefillCLIAdmission.swift)
(`preflight`) and [QwenLayerStageSoloPrefillAdmission.swift](Sources/ClusterInference/QwenLayerStageSoloPrefillAdmission.swift)
(`admitQwenLayerStageSoloPrefill`) enforce these checks before the timer.

## Native interval and final comparison

[QwenLayerStageSoloPrefillRequest.swift](Sources/ClusterInference/QwenLayerStageSoloPrefillRequest.swift)
(`runQwenLayerStageSoloPrefillRequest`) starts `DispatchTime` immediately before
constructing a fresh `CBv2RequestSession`. Intermediate chunks request only an
evaluation handle; the final chunk retains one `[1,V]` native row. It then runs
uncast native argmax and the all-logits-finite reduction, evaluates their roots,
reads the scalar token and validates its bounds before stopping the clock.
This matches the stage path's selection operations and output narrowing; solo
adds no artificial transport, residual copying or ACK delay.

The interval includes fresh request state, all prompt forwards and state
commits, final norm/head, bounded commit metadata, finite argmax and scalar
readback. It excludes verified loading, reference/input preparation, readiness,
final state/logit capture, reference comparison and retirement. Start, stop and
elapsed nanoseconds remain exact UInt64 values. A separate post-stop duration
extends through request close, excluding later model release and report output.
This is a matched-chunk control, not a claim to the fastest eligible solo path.

After stop, the owner copies and hashes the actual native logit bytes once,
compares their metadata/digest and selected token with the reference, and takes
one complete final state metadata/digest snapshot. It performs no per-frame
state or full-logit captures. `referenceMaximumTieCount` records the reference
annotation; the candidate does not separately compute a tie count.
[QwenLayerStageSoloPrefillObservation.swift](Sources/ClusterInference/QwenLayerStageSoloPrefillObservation.swift)
(`select`, `capture`) keeps selection and byte capture on their respective
sides of the timer.

`nativeLogitBytesCompared=false` remains explicit: no second baseline byte
array is resident for a native byte-for-byte comparison. Candidate output
exports metadata/SHA rather than full logit values or raw state. Successful
digest equality is scoped to the pinned reference and this admitted request;
it does not establish model quality or broader workload equivalence.

The ready record reports verified weights with no fresh request state yet.
A successful terminal `qwen_layer_stage_solo_prefill_report` requires complete
request retirement, stream synchronization, weak-model release verification
and cache clearing. Request failure cancels owned state and preserves a cleanup
failure alongside the primary error. The launcher must still supervise the
process as a whole. [QwenLayerStageSoloPrefillCheck.swift](Sources/ClusterInference/QwenLayerStageSoloPrefillCheck.swift)
(`runQwenLayerStageSoloPrefillCheck`) owns that outer lifetime; the CPU-only
request result does not itself claim model release.
