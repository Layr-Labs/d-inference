# Dense Qwen CBv2 integration — 2026-09-13

The experimental `cbv2-contiguous` execution path calls dense Qwen's actual
production CBv2 model adapter, prompt output narrowing and request-owned
KV/conv/SSM state transactions. The initial tiny Float32 smoke test passes in
solo, FFN-TP and full-TP modes, with exact logits against each corresponding
ordinary-path run. **This is model/state integration evidence, not production
scheduler, paged-backend, real-artifact or target-hardware qualification.**

## Integration boundary

The source audit distinguishes ordinary dense CBv2 prefill/decode from the
specialized A3B captured-MTP verification path. Dense MTP-off CBv2 continues to
call the FFN down, attention output and GDN output `Linear` overrides. Retaining
the concrete `Qwen3NextMLP` permits the pinned decoder's typed dispatch, and
leaving GDN input projections unchanged preserves their eligible fusion.
Whole-MLP substitutes used by ordinary MoE/local oracles are rejected here.

The A3B verification helper instead reads packed arrays directly and can bypass
those overrides. Its fixed kernel geometry also requires revalidation after
partitioning. Neither execution path enables it. This finding narrows the
earlier broad concern about CBv2 fast paths: dense MTP-off integration does not
require a pinned model-source fork.

`RequestExecution.swift` separates request state from token selection and
transport coordination. The ordinary implementation retains the previous
prepare/forward calls. `CBv2RequestSession.swift` calls
`CBv2SteppableLanguageModelAdapter.recurrentPrefill` for intermediate/final
chunks and its recurrent `forward` for decode. It never delegates CBv2 work to
the ordinary model forward. Each rank creates cache and recurrent geometry from
its actual loaded model, including local head counts under the full plan.

Intermediate prefill evaluates a hidden handle and avoids discarded vocabulary
projections; the final chunk projects one vocabulary row. Each step evaluates
output plus KV/device-offset and recurrent roots, checks the MLX error handler,
validates ownership, shapes, dtypes and token advancement, and then commits the
recurrent generation. Cleanup releases bindings before rows and recurrent
ownership, with no reuse of a failed request. Native deadlines remain necessary
for stalled collectives.

Every CBv2 TP request checks its floating reduction count against layer count,
partition and number of forwards. Int32 control/token collectives are excluded.
This catches missing or duplicated output hooks. Request construction and state
assertions, including device-offset host readback, are inside measured work;
these timings describe this synchronous path with those checks enabled.

## Identity and scope

`--execution-path ordinary|cbv2-contiguous` is required as `executionPath` in
schema-8 reports and protocol-4 worker identity; `ordinary` is the explicit
default. Peers agree on it before inference. Old reports/worker versions,
missing or mismatched path values, and unsupported families fail closed.
Native metadata preflight checks the promised path before worker readiness.

Support is restricted to dense Qwen and serialized text requests, with no MTP,
prefix reuse, padding, multimodal input or state handoff. CBv2 uses contiguous
KV; it does not run the production scheduler or segmented paged backend. The
source limit is prompt plus output count at most the lesser of declared context
and 32,768, and at most 4,096 output tokens. MoE/Gemma retain ordinary execution.

The initial six-run smoke uses `tiny`, Float32, seed 7, 65 prompt tokens in
chunks of 32, and eight teacher-aligned outputs. Its CBv2 solo/TP comparisons
have worst-row relative RMS below `8e-7`; both partition plans pass the unchanged
strict bounds and all paired argmax choices agree. Each CBv2 mode's logits equal
its ordinary counterpart exactly. The immutable local smoke directory is
`cbv2-smoke-20260913`.

The native protocol check passes 4,112 accepted fixtures and 95 rejections.
Its version-4 canonical request SHA-256 is
`168a6c912b4c38f111ef02b46d86a512a4132c604cb8f1dcda94b452cb186cd3`,
independently reproduced by Python. The 162-test Python suite covers execution
path identity, family/count restrictions, forwarding, request reuse, cancellation
and mismatch fencing. Numerical whole-model validation is separate from those
CPU protocol tests.
