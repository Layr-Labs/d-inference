# Registered 9B long-prompt reference

> Last updated: 2026-09-14 · commit `e4df336bc`

The experimental `qwen-long-prefill-reference` command produces a full-model
correctness reference for the registered Qwen3.5 9B artifact at 8,192 prompt
tokens, chunk 512 and one selected output. Its [guarded native validation](QWEN_LONG_PREFILL_REFERENCE_VALIDATION.md)
passed the independent numerical and provenance audits on a 24 GiB M4 Pro. It measures no
inference duration and makes no throughput claim.

## Input and source admission

[QwenLongPrefillReferenceCLI.swift](Sources/ClusterInference/QwenLongPrefillReferenceCLI.swift)
requires native CBv2 execution, one repetition, zero warmups, no teacher tokens
and a deadline of at most 300 seconds. The model aggregate and raw prompt file
require explicit SHA-256 pins. `--long-prompt-sha256` is shared by the explicit
long reference, pair, rank and solo commands.
The prompt is retained once, bounded to 64 KiB, checked against its raw digest,
and parsed through the strict integer JSON scanner before MLX initialization.

[QwenLongPrefillReferenceAdmission.swift](Sources/ClusterInference/QwenLongPrefillReferenceAdmission.swift)
admits exactly 8,192 in-vocabulary tokens in sixteen 512-token frames. It uses
the separate registered budget from the [long-profile contract](QWEN_LAYER_STAGE_LONG_PREFILL.md).
The actual process arithmetic environment is admitted before the first MLX
array is created; its canonical receipt digest accompanies the reference.
The verified loader then checks the complete source artifact and actual native
BF16 activation dtype. A configuration or resource receipt alone does not
establish successful model loading.

Optional `--stage-cut` binds the reference source to a
[registered stage plan](QWEN_LAYER_STAGE_CANDIDATES.md). The full-model forward
stays unchanged; omission selects the historical 16+16 plan. A reference from
another plan cannot qualify a selected-cut pair or rank execution. The existing
validation report covers the default plan.

## Reference production

[QwenLongPrefillReferenceProducer.swift](Sources/ClusterInference/QwenLongPrefillReferenceProducer.swift)
owns one complete model load and one fresh request. Fifteen chunks return
evaluated narrow handles; the final chunk returns the full vocabulary row.
Every chunk commits its recurrent and attention state through the existing
CBv2 forward path. No intermediate numerical history or second model is kept.

After all tokens commit, the producer evaluates native finite-check and argmax
scalars, captures the final row once and verifies the selected index against
its copied values. It captures the final state once as metadata and digests.
The final state contains 72 components and 319,946,784 logical bytes; the BF16
logit row contains 248,320 values and 496,640 native bytes. These are component
sizes, not a whole-process memory bound.

The request closes before its complete model leaves scope. Error paths clear
the owned final logits, cancel an open request and preserve the primary error
alongside cleanup failures. The outer scope verifies weak model release and
clears the MLX cache. A separate process deadline is still needed for stalled
native work.

[QwenLongPrefillReferenceEvidence.swift](Sources/ClusterInference/QwenLongPrefillReferenceEvidence.swift)
binds the profile, exact prompt, arithmetic receipt, verified source, all sixteen
commit records, final state, native logit bytes and selected token. The output
is two JSONL records: pre-load admission followed by the completed reference
and before/after MLX allocation observations. All returned evidence is CPU
data; no native array or request owner escapes.

This reference does not compare distributed output. A future candidate must
use the same chunk geometry, independently pinned inputs and matching source
and arithmetic identities. The public short-prefill launcher does not admit
this workload. Native execution requires a separate guarded launcher with
OS resource admission, bounded output and process cleanup.

Related: [long-profile tiny validation](QWEN_LAYER_STAGE_LONG_PREFILL_VALIDATION.md),
[inference checks](README.md), [distributed goal](../../../docs/design/distributed-inference-goal.md).
