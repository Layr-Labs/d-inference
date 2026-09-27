# Actual attention metadata with confirmed sample identity

> Last updated: 2026-09-06 · commit `5b93195c9`

The standalone benchmark can observe original attention input and cache dtypes
at one ordinary decode position without another model forward or tensor readback.
Native, benchmark and wrapper tests pass. Actual Qwen metadata, numerical
reference comparison and the unresolved backend output differences remain open.

## Behavior and bounds

Native commit `847e32076abd1c7f2b28660b7deed902f5dec692` adds default-nil
`CBv2AttentionMetadataConfig` and binds the concrete caches only around the
selected normal forward. It captures host metadata for original post-RoPE Q,
incoming K/V, native backing storage, scale, offsets, compact/model layer indices,
actual dispatch, kernel output and outward output. Contiguous SDPA, fixed paged
decode and segmented paged decode keep their original arithmetic and inputs.

Selection requires an idle-configured MTP-off engine, ordinary B1/L1 text decode,
full-attention owners without shared KV, sinks, softcap or spans. At most one
forward, 128 owner records and 64 segment descriptions per owner are retained.
Shapes and strides describe graph construction; they do not prove evaluated
physical layout. No tensor handle or raw contents live in the host snapshot.

The existing request/sample lifecycle confirms or discards the capture. Direct
decode uses generated count; chained decode uses generated count plus one.
Concrete bindings clear in defer; failed, discarded and shutdown work cannot be
reported as a confirmed observation. The benchmark reports `captured` only for
one confirmed forward with complete owners and no refusals. Other observations
remain `inconclusive`.

## Validation

Nine native filters pass: 62 functions and 129 expanded cases, including eight
new functions and 16 expanded cases. They exercise native BF16/FP32 storage,
wider FP32 queries, all ten compact owner mappings, record bounds, unsupported
geometry, failure and cancellation. Ordinary direct/chained controls preserve
tokens, forward shapes and real recurrent-state staging. Existing logit,
recurrent, paged dtype, kernel and segment suites also pass.

Fourteen benchmark tests pass, covering metadata options, combined metadata/logit
flags, existing logit options and coherent idle observations. Twelve Python
wrapper tests pass independently. The native and benchmark builds complete in
71.00 and 92.74 seconds. No test skips or production source corrections occur.
The combined-options addition changes two test files only.

Root verifies all source/validation payloads, all 894 canonical native inputs
against the committed tree, and 759 declared native/dependency/Jinja references
in the native build graph. Benchmark graph references resolve to the tested
candidate. Graph membership alone is not a claim that every target is linked
into the selected executable. The existing local dependency-only package
overlays and pinned metallib are retained. SwiftPM's unused remote MLX checkout
does not supply the compiled MLX sources.

The first probe plan retained stale byte-size annotations for two updated tests;
its successor corrects those annotations. Actual hashes, compiled source,
validation payload sizes and test results are unchanged. The successor binds
the completed benchmark evidence. The optimized probe and real-model runs are
separate work and are not asserted by this source milestone.

## Evidence and remaining interpretation

The [manifest](evidence/attention-metadata-2026-09-06/manifest.json) and
[archive](evidence/attention-metadata-2026-09-06/payloads.tar.gz) preserve
199 verified payloads (7,264,903 bytes).
They contain source freezes, raw tests, build graphs, corrected source union
and root reviews. Compiled binaries and model weights are excluded.
Manifest SHA-256: `808773dcfeda2b1a8bd056426da6597503e251053ae53677d87300d7c87f9e09`.
Archive SHA-256: `4acd51262cc1a61adde8ed3e205b74bbda69e13585766f58387755de3fd05880`.

Use the [benchmark instructions](../developer/test.md#prefix-cache-benchmark-validation)
and compare identical uninstrumented/traced trajectories before interpreting
metadata. These observations cannot establish Q/K/V equality across backends or
numerical accuracy. Bounded raw tensor packets and an independent FP32 reference
remain required to investigate the [actual Qwen logit difference](2026-09-05-qwen36-actual-logits.md).
Diagnostic timings are not performance evidence. Cache defaults and release
activation are unchanged.
