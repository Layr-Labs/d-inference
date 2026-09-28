# Registered 9B long-prompt solo control

> Last updated: 2026-09-14 · commit `e4df336bc`

`qwen-long-prefill-solo-check` measures one full-model request with the exact
8,192-token prompt and chunk size 512 used by the
[long-prompt rank path](QWEN_LONG_PREFILL_RANKS.md). Its
[guarded native run and independent audits passed](QWEN_LONG_PREFILL_SOLO_VALIDATION.md).
Its clock runs from fresh
request-state construction through native finite argmax and scalar readback.
Final state/logit digests and retirement follow stop.

## Workload and ownership

[QwenLongPrefillSoloCLI.swift](Sources/ClusterInference/QwenLongPrefillSoloCLI.swift)
reuses the registered reference's complete model/input/arithmetic admission:
one output, one repetition, no warmups, no teacher history, native CBv2, exact
artifact/raw-prompt pins, seed 7 and timeout at most 300 seconds. It accepts
no rank epoch, stage policy or external reference file. The actual arithmetic
environment and retained input bytes are admitted before MLX initialization.

[QwenLongPrefillSoloCheck.swift](Sources/ClusterInference/QwenLongPrefillSoloCheck.swift)
loads one verified complete model, preserving stored quantization and disabling
MTP. The request owner admits the actual source and checks native errors before
emitting the loaded-model ready record. No request state exists at that point.

[QwenLongPrefillSoloRequest.swift](Sources/ClusterInference/QwenLongPrefillSoloRequest.swift)
starts its clock immediately before constructing a fresh `CBv2RequestSession`.
It performs the same sixteen 512-token forwards as the
[validated full-model reference](QWEN_LONG_PREFILL_REFERENCE_VALIDATION.md).
The first fifteen return narrow evaluation handles; only the last retains the
complete BF16 vocabulary row. Every commit checks the actual native frontier,
shape, dtype and zero decode-forward count.

[QwenLongPrefillSoloObservation.swift](Sources/ClusterInference/QwenLongPrefillSoloObservation.swift)
performs native argmax, complete-row finiteness and scalar readback before stop.
After stop it copies and hashes the final native row once, exports only metadata,
and captures the 72 final state components as metadata and digests. It does not
invent a stage identity or export full Float values.

The request closes before the model scope ends. Weak model-release checks,
synchronization and cache clearing follow. Errors cancel an open request and
preserve the primary failure plus cleanup errors; late failures do not cancel
an already retired healthy owner again. External process supervision remains
necessary when a native call cannot return.

## Evidence and interpretation

The process emits ready/report records. The report includes the actual verified
source receipt, profiled prompt history, sixteen scalar commits, native selection,
final state/logit metadata, diagnostic interval and four memory observations.
It makes no native candidate/reference comparison. An independent CPU auditor
must compare the source, prompt, arithmetic, complete final state/logit digests
and selected token with a separately pinned full-model reference.

The clock includes fresh state, all forwards, commit metadata and finite argmax.
It excludes loading, initial source admission, ready-record output, final
numerical captures and retirement. The separate post-stop interval extends
through request close, excluding later model release and cache clearing.
The rank path includes transport, scalar action tracing and repeated source
admission inside its context constructor; those are real additional costs.

A single fresh-process interval does not establish warmed resident throughput,
a scheduling speedup or a physical cluster result. Comparisons must retain
execution order and initialization effects. This 9B control does not measure
27B or M3 Ultra performance and does not qualify the 800 TPS release target.

Related: [registered reference](QWEN_LONG_PREFILL_REFERENCE.md),
[whole-layer validation](QWEN_LONG_PREFILL_PAIR_VALIDATION.md),
[inference checks](README.md).
