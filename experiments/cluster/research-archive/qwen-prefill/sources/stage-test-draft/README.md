# Tiny layer-stage loader fixture draft

Source-only drafts; no compilation, tests, native execution, or model evaluation
has been run by the drafting agent. Root owns integration and bounded execution.

Copy these three Swift files together:

- `QwenLayerStageFixture.swift`: deterministic tiny dense model with 8 layers,
  interval 4, seed 7, hidden 128, vocabulary 512, native W4/G64. Supports direct
  `qwen3_5_text` or nested `qwen3_5` construction. Uses the established fixture
  writer, then the ordinary saved-model loader to establish the dtype oracle.
- `QwenLayerStageLoaderCheck.swift`: loads two verified stages, checks both,
  rejects a wrong aggregate, and completes corruption/deletion ownership proof.
- `QwenLayerStageLoaderOracle.swift`: independently derives 4+4 name ownership
  from ordinary model parameters, compares every active tensor's shape/dtype/
  logical bytes and compact ownership, validates inert arrays separately, and
  binds source/active/inert accounting to the returned loader receipts.

Root sequence, inside its MLX error/timeout scope:

```swift
let fixture = try QwenLayerStageFixture(options: options, directory: temporary,
    fp16FFNMetadata: fp16Metadata, wrapped: wrapped, check: check)
let loaderCheck = try QwenLayerStageLoaderCheck(fixture: fixture, check: check)
let loaderResult = try loaderCheck.completeLoaderProof(check: check)
// Source files are now removed; use only resident models for later parity.
let baseline = fixture.baseline
let stages = loaderCheck.stages
```

Root must remove the newly created temporary directory on errors as well.
Successful completion removes only that fixture's directory. Session helpers
must not attempt to reload the checkpoint after `completeLoaderProof()`.

Initial matrix is exactly F32 direct, BF16 wrapped, and BF16 wrapped with F16
layer quantization metadata. There are 237 canonical source tensors, independently
assigned 118/119 active tensors, plus separately checked 2/1 inert parameters.
The optional F16 case stores exactly 124 layer scale/offset tensors as F16 and
requires the ordinary loader to convert all of them to BF16 before comparison.

Complete the loader proof before any stage or baseline transformer forward.
Native GDN fusion legitimately turns named projection parameters into views;
the unique compact zero-offset buffer assertion applies before that mutation.
No source→local mapping/selection helper from the planner or loader is used by
the independent expected-name derivation. Name counts, active byte conservation,
and inert storage are all distinct checks.

Wrong-pin and corrupted-file attempts must return no stage; parameter handles
of already loaded stages must remain unchanged. The check does not claim to
observe every temporary allocation inside a rejected invocation. The emitted
loader result makes no model-forward, continuation, throughput, or RDMA claim.
