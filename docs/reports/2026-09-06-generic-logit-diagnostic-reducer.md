# Logit diagnostics without model policy coupling

> Last updated: 2026-09-06 · commit `36d2f559e`

Optional logit diagnostics now use a common top-two reducer when the selected
step has no retained policy reduction. The actual Gemma adapter passes ordinary
and confirmed MTP capture tests without gaining Qwen policy eligibility. All ten
native suites pass; the full-model Gemma QAT rerun remains pending.

The [actual QAT failure](evidence/generic-logit-reducer-2026-09-06/qat-failure-analysis.json)
occurs after eight warmup tokens, when installing the trace throws
`topTwoUnavailable`; both main rows remain unrun. Its uninstrumented control
completes 61 tokens and preserves all seven historical trajectories. The failed
attempt and its full evidence remain in this milestone's archive.

## Source and policy behavior

Native commit `b01e1af06902c82e22227bf923447cc71c47b148` changes nine files
from base `dcf39f6b43effaa2b483211c97d7d3a3e7c0269b`.
`Libraries/MLXLMCommon/ContinuousBatchingV2/CBv2TopTwo.swift`
(`cbv2TopTwoRows`) extracts the existing Qwen reducer into package access.
Its three complete Metal strings, pipeline names, launch geometry, output
dtypes, tie ordering and NaN handling remain exact. The Qwen function becomes a
thin wrapper. `CBv2LogitDiagnostic.swift` reuses a retained policy reduction when
present and otherwise calls the common reducer. `EngineLoopV2.swift` retains
idle/configuration checks and removes the unrelated family capability gate.

No model conformance, adapter capability or MTP policy selection changes. Seven
policy/model/adapter files match the base byte for byte. Default-nil diagnostics
continue to return before constructing diagnostic reductions. The unused
`topTwoUnavailable` case is removed from the diagnostic SPI error enum.

## Validation and preserved failure

Ten native suites pass: 96 distinct functions and 105 expanded cases, with no
skips. The six new functions cover eleven cases: FP16/BF16/FP32 inputs, physical
noncontiguous strides, ties, signed zero, NaNs/infinities, wider values,
production vocabulary width and exact reuse of a supplied policy reduction.
The actual tiny Gemma adapter is configured after warmup and captures ordinary
decode plus confirmed serial/rectangular MTP columns. Controls preserve tokens,
verification geometry, acceptance/depth counters and marginal-policy eligibility.
Existing Qwen reduction, logit lifecycle, attention packet, MTP engine, Qwen MTP,
paged execution and depth-controller regressions also pass.

The first source version compiles, but three test setup assertions inspect a
lazy transpose's placeholder stride before evaluation. Their arithmetic checks
pass. Source2 adds only `eval(logits)` before that physical-stride assertion;
the other eight files and all production bytes are unchanged. The failed run,
raw logs, source1, one-line correction and fresh validation2 are retained.

Validation2 builds in 63.72 seconds. It verifies 909 canonical native inputs,
910 compile inputs, 1,356 dependency inputs and 27 Jinja files. Only the reviewed
local dependency overlay and pinned resolution metadata differ from canonical
package metadata. The frozen graph matches 504 native, 256 dependency and 14
Jinja source references. Graph membership does not assert that every declared
target links into the selected test product. SwiftPM's unused remote MLX
checkout is excluded from the actual MLX source graph.

## Evidence and remaining work

The [manifest](evidence/generic-logit-reducer-2026-09-06/manifest.json) and
[archive](evidence/generic-logit-reducer-2026-09-06/payloads.tar.gz) retain
160 verified payloads (6,771,823 bytes), including the nested 134-payload actual
QAT failure archive. Compiled binaries and model weights are excluded.
Manifest SHA-256: `c3692926a8eef7e4d1b1f833fcc0f677830f5ad084016223ea2c702652e1a43b`.
Archive SHA-256: `36467c77f59dcfb6156e6ca5724b68551898b08ce39b324cf3127e86ebdacf35`.

The [benchmark instructions](../developer/test.md#prefix-cache-benchmark-validation)
still require a control from the same build and exact confirmed context. Tiny
family fixtures establish the diagnostic seam and unchanged policy behavior;
they do not establish full-model output parity, numerical accuracy or speed.
A rebuilt probe and real Gemma QAT control/trace rerun remain pending. Cache
defaults and release activation remain unchanged.
