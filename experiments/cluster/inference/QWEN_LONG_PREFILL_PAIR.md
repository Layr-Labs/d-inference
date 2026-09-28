# Registered 9B long-prompt stage comparison

> Last updated: 2026-09-14 · commit `e4df336bc`

`qwen-long-prefill-pair-check` is an experimental correctness check
for the registered Qwen3.5 9B model at 8,192 prompt tokens and chunk 512. Its
[guarded native comparison and independent audits passed](QWEN_LONG_PREFILL_PAIR_VALIDATION.md).
It compares a complete model with two full-width stages in one process and
reports no inference time.

## Work and ownership

[QwenLongPrefillPairCLI.swift](Sources/ClusterInference/QwenLongPrefillPairCLI.swift)
reuses the exact model, prompt, arithmetic and resource admission of the
[reference command](QWEN_LONG_PREFILL_REFERENCE.md). The separate mode requires
one output, one repetition, no warmups or teacher tokens, and explicit raw
prompt and artifact SHA-256 pins. It does not widen earlier diagnostic modes.

[QwenLongPrefillPairCheck.swift](Sources/ClusterInference/QwenLongPrefillPairCheck.swift)
first produces a fresh full-model reference using the same sixteen chunks.
The full model and its request retire before either stage loads. A checkpoint
retains that CPU reference even if later stage loading or comparison fails.
The driver loads the two admitted ranges through the verified stage loader.
Omission of `--stage-cut` keeps layers 0–15 and 16–31. An explicit
[registered cut](QWEN_LAYER_STAGE_CANDIDATES.md) changes the stage ranges and
binds the fresh reference to that plan before model loading. The separate
[12+20 native comparison](QWEN_LONG_PREFILL_UNEQUAL_VALIDATION.md) passed with its
fresh full-model reference and independent numerical validator.

[QwenLayerStageProfiledPrefillComputeContext.swift](Sources/ClusterInference/QwenLayerStageProfiledPrefillComputeContext.swift)
wraps the existing stage session and full-width forward. Its separate admission
binds the actual loaded source, storage plan, prompt, profile, arithmetic receipt
and v4 agreement before creating fresh request state. Each stage commits the
same frontier after evaluating its state and output. The context permits one
native token selection and one final diagnostic observation.

[QwenLongPrefillPairComparison.swift](Sources/ClusterInference/QwenLongPrefillPairComparison.swift)
performs sixteen consecutive producer/copy/consumer steps. It creates v4
envelopes from actual producer metadata and checks their local decode against
the exact expected frame. Each native residual copy is consumed before the
next frame. This exercises local metadata and ownership; it uses no sockets,
network acknowledgements or physical transport.

## Final comparison and limits

After both stages complete and stage one selects its finite argmax, each stage
captures its admitted final state components once (36 each for the default
split, 27 and 45 for cut 12). Their disjoint global indices
combine into the reference's 72 components. Stage one captures the full final
logit row's metadata and native-byte digest without exporting another array of
Float values. The driver compares all state metadata/digests, the complete
logit-row metadata/digest and selected token with the fresh reference.

This candidate comparison uses recorded digests; it does not compare the
candidate's raw bytes directly with retained reference bytes. Native boundary
copies remain in the execution path. No per-frame state snapshots, intermediate
vocabulary rows, inference clock or performance warmup are hidden in this check.

Both requests close before stage-model release checks and cache clearing.
Failures cancel every remaining open owner while preserving the primary error
and cleanup failures. Already retired healthy owners are not cancelled again.
Partial loading and post-close failures unwind model ownership before the outer
cleanup check. A separately guarded process deadline remains required.

The command emits a complete-reference checkpoint followed by the pair report,
stage loading receipts and memory observations. The independent pair-output
validator and guarded launcher are separate tools. The passing single-process
comparison qualifies this tested arithmetic and ownership path; physical
transport, timing and performance require further execution.

Related: [long-profile contract](QWEN_LAYER_STAGE_LONG_PREFILL.md),
[reference validation](QWEN_LONG_PREFILL_REFERENCE_VALIDATION.md),
[inference checks](README.md).
