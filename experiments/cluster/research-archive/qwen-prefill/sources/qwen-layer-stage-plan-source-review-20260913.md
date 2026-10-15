# Independent Qwen layer-stage planner source review

Reviewed 2026-09-13 against the integrated planner and pinned MLXLLM sources.
This is a static source review. No files were edited in the repository, and no
native execution, tests, build, tensor loading, or artifact rehash was performed.

No concrete stage-ownership, canonical-name, namespace, quantization-reindexing,
or constructor-default defect was found in the reviewed implementation.

Reviewed source SHA256:

- `QwenLayerStagePlan.swift`: `d3ccab7ac3531ea34c5bb64ec70c07d03d2a273306a38f9e8f7ff85dccbda97e`
- `QwenLayerStageMetadata.swift`: `3bd2e10b6f6f6be67f1d896f4c8e312260e3c422d14e9f4fe2139cd6726a67b4`
- `QwenLayerStagePlanCheck.swift`: `6d80ffde6a029fff5d4f1bb7eac4f526f588936acfe23834e6daba00e9d6f8c2`

The review read the existing admission and actual-9B metadata receipts; their
execution results were not rerun. Their 927 mapped text names and 364 excluded
vision/MTP names are name-coverage evidence, not payload or stage-execution proof.

Evidence checked in source:

- `ModelLoading.swift:184` constructs the MLXLLM `Qwen35Model` wrapper for
  `qwen3_5`, including the flat fallback admitted by `Qwen35Configuration`.
  `qwen3_5_text` uses the direct text model. The planner's `language_model.`
  versus bare namespace matches those concrete constructors.
- `Qwen35.swift:120` supplies `tie_word_embeddings = false` when absent.
  The MLXLLM wrapper reads its nested text config directly; it does not propagate
  a root tie flag into that config. Rejecting explicit true at either level is
  conservative and preserves the planner's exclusive embedding/head ownership.
- `Qwen35DecoderLayer` chooses layer kind from `(localIndex + 1) % interval`.
  Stage starts aligned to that interval preserve each global layer's kind.
  The planner requires both stages to contain at least one full interval, also
  retaining the constructor's expected initial recurrent/full-attention slots.
- Mandatory parameters agree with the pinned dense constructors: unbiased
  projections and convolution, attention q/k norms, recurrent gated norm,
  `A_log`/`dt_bias`, two layer norms, and the untied embedding/final norm/head.
  Direct recurrent parameters are renamed as parameters, without inventing a
  trailing `.weight`. Canonical layer spelling and unknown paths are rejected.
- `BaseConfiguration.QuantizationContainer` recognizes the same six global
  metadata keys retained by the planner. `resolveQuantization` prefers an exact
  module override, then aliases, then the default. The pinned Qwen alias helper
  only remaps routed-expert paths; ordinary dense paths have no alias fallback.
  The planner correctly rejects noncanonical dense overrides and rewrites owned
  canonical overrides to each stage's local layer index. Explicit `false` and
  retained global defaults preserve the original policy; inert paths get `false`.

Integration obligations already stated by the planner remain necessary:

- Replace inactive modules before evaluating any model parameters. A declared
  inert path alone does not remove its original lazy allocation or weights.
- Stage 1 must bypass embedding with the incoming residual while retaining the
  original checkpoint activation dtype in its floating inert embedding weight.
  `Qwen35+CompleteCheckpoint.swift:10` derives activation/KV dtype from embedding
  metadata, even when the forward path bypasses the embedding. A generic F32
  placeholder could therefore create incorrect BF16 cache/state specifications.
- Stage cache and recurrent-state indices are local to the compact model.
  `Qwen35.swift:1717` explicitly checks attention `modelLayerIndex` against local
  enumeration. Global layer indices belong in provenance/ownership mapping.
- `parameters(canonicalSourceNames:)` proves mandatory names, ownership, and
  injectivity only. It intentionally accepts optional scales/biases individually;
  the verified loader must compare the constructed active inventory and validate
  complete quantization triplets, descriptor shapes/dtypes, widths, byte budgets,
  sanitizer transformations, and artifact identity before tensor payload reads.
- The planner preserves RoPE/config metadata and admits a conservative explicit
  geometry subset. It does not qualify every retained metadata value for runtime,
  implement the stage session, prove continuation/cache equivalence, or measure
  pipeline throughput. Those are outside these name/configuration checks.
