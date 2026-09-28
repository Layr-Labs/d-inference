# Registered long-profile stage compute draft

Source-only, 2026-09-14. Six new Swift files; no existing source or v3 bound is
changed. No compilation, native execution, model payload read, SSH, transport,
timing result, or candidate/reference comparison has been performed here.

## Exact scope and construction

`QwenLayerStageProfiledPrefillComputeContext(loaded:local:agreement:check:)`
accepts one actual verified `LoadedQwenLayerStage`, retained
`QwenRegistered9BLongPrefillReferenceAdmission`, and the new v4
`QwenLayerStageProfiledPrefillStartAgreement`. It admits only the registered
BF16 Qwen source, explicit `long_prefill_8k_v1`, 8192/512/output1/batch1,
no teacher/decode, and the existing full-width 16+16 layer plan. The broader
profile's maxima do not authorize another model or request here.

The reference producer dependency was reviewed at frozen manifest SHA256
`55793df7791aa60ed79ac6d6a7d9b5f1eb18283514a0b5be6d9593846511b78c`.
Only its retained local admission type is needed. No reference evidence,
reference fingerprint, full reference logits, decoder, or trust-by-copied
reference DTO is accepted. A future independently pinned strict reference
descriptor and CPU comparison remain separate work.

`QwenLayerStageProfiledComputeAdmission` checks the local stage receipt,
canonical storage-commitment hash and byte conservation, both compact stage
configuration/plan hashes, BF16 conversion/activation, complete source counts,
and current loader source/host-tensor caps. It reconstructs the expected v4
agreement from independently admitted local metadata and requires exact
fingerprint equality, including logical prompt history, profile and arithmetic
environment. Epoch uniqueness and cross-rank readiness remain the coordinator's
responsibility. The canonical source layout is metadata identity, not a new
resident-content hash or a substitute for verified loading.

Actual process environment admission must occur before MLX initialization.
The retained admission and v4 agreement bind the canonical receipt SHA; this
context does not reread globals or prove retroactively what native libraries
latched. The registered 745,345,056-byte named-tensor estimate remains under
its separate 768 MiB ceiling, not a whole-process memory guarantee.

The owner helper constructs `QwenLayerStageSession(...profiledRequest:)` and
checks a fresh zero frontier. It reuses the session's actual model layout,
frozen topology, ingress, compact geometry and state checks. Constructor or
callback failure retires any constructed owner before it escapes. There is no
copied model forward, additional model load, parameter mutation, cast, TP or MTP.

## Per-frame API and transport responsibilities

`expectation(for:)`, `prepare(_:check:)` and
`consume(_:boundary:check:)` accept only the exact next step from the retained
immutable history. Both roles use the existing session's evaluation of output,
KV and recurrent roots, checks, generation commit and residual hashing.
Stage zero returns `[1,512,4096]` BF16 hidden; stage one returns fifteen `[1,1]`
evaluated handles and one `[1,248320]` BF16 final row.

`QwenLayerStageProfiledPrefillPrepared` carries the caller-owned native
boundary, new profiled expectation and existing small CPU commit DTO. The
context never retains that boundary. Actual producer frame/source/dtype/shape/
byte-count metadata is validated against the new header expectation; a
received payload must still pass the unchanged native owned/compact-buffer
checks, hash comparison and completion fences. No unique-storage claim is
made prematurely inside prepare.

The forthcoming v4 transport must retain exactly one CPU nonce ticket and
one pending consumed-ACK slot. Reuse the existing policy order: complete the
received ACK, release the original producer array, optionally prepare only the
next prompt chunk, drain the prior consumed ACK, then send another header.
The context advances only its local native frontier and cannot prove that a
caller released an older residual. A second native prepared slot or a header
sent with an undrained predecessor must remain a driver/transport rejection.

On stage one, consume commits the actual frame; the final call must be followed
by `selectFirstToken(check:)` before constructing the token packet/consumed ACK.
Selection evaluates native uncast full-row `argMax` and `all(isFinite)`, checks
the UInt32 scalar contract, and reads the finite flag/token. It is one-shot and
returns the existing CPU token receipt for v4 binding. No route forcing,
normalization change, tie count borrowed from a reference, or second token
selection is introduced.

## Final-only evidence and retirement

After rank zero has received/admitted the first token, recorded its stop, and
completed external post-stop release, both ranks may call
`captureFinalDigestsAfterPostStop(check:)` once. This method contains no clock
or transport object; its name does not prove the external release occurred.
The future driver must enforce it. If timing wraps the entire initializer,
its CPU source-admission/hash work is included too; no isolated compute timing
is implied by this API.

The sole final state snapshot retains no raw bytes. Its actual local/global
mapping, complete component set, shapes, dtypes, byte counts and digests are
checked against retained registered geometry. Both stages use the established
global baseline state-key/fingerprint convention. For this configuration,
each stage has 36 entries and 159,973,392 logical bytes; merged coverage is
72 entries and 319,946,784 bytes. Conv state is BF16, SSM Float32, KV BF16 and
position offsets Int32. These are metadata-derived logical sizes, not RSS.

Stage one copies and hashes its final 496,640-byte BF16 row once, then discards
the CPU bytes before returning metadata. No candidate Float values or raw row
escape. The final evidence carries profile/agreement/history, source receipt/
layout/storage, prompt and arithmetic bindings. It explicitly reports
`modelForwardCompared:false`, `throughputMeasurementValid:false` and
`requestStateRetirementStillRequired:true`. It is not a success/comparison report.

Call `close()` explicitly after evidence creation; the outer coordinator may
claim retirement/model release only after observing those actual conditions.
Keep weak-model release proof outside this context. On a primary error use
`cancel()` only for an owner that still needs retirement, preserving the
original error if cleanup also fails. Recursive callbacks poison the context;
the safe outer operation boundary then cancels native state after unwinding.
Any late failed callback invalidates returned evidence. Native synchronization
can still stall, so a hard whole-cohort process deadline remains necessary.

## Required root validation

Root must compile these source drafts with the frozen geometry/v4/reference
dependencies. Meaningful first checks should reject changed source/config/
storage/environment/agreement/history before fresh state; wrong stage role,
off-frontier frame and duplicate final selection/observation; callbacks during
construction, a middle commit, final scalar/copy/snapshot and cleanup; and
reentry during checked native work. Verify all failures retire owners and
produce no success report. Then compare actual final digest/token evidence to
an independently validated same-chunk 8K full-model reference. This draft does
not bypass those checks or admit long-profile v4 transport by itself.
