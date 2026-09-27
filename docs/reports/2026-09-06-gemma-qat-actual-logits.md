# Gemma QAT captures real MTP logits with backend divergence retained

> Last updated: 2026-09-06 · commit `bd8dee802`

All four real-model cells pass their integrity checks. The generic diagnostic
captures one confirmed decision in Gemma's normal MTP path on each backend,
and each trace preserves all seven completed control trajectories exactly.
The strict contiguous-versus-paged token comparison still fails: their main
outputs first differ at index 7 and finish with 61 versus 38 tokens.

## Exact runtime and controls

The [optimized diagnostic probe](2026-09-06-generic-qat-release-probe.md) uses
parent `6790dea1c7044ca336cd6383aac7e6d27afb7359`, native
`b01e1af06902c82e22227bf923447cc71c47b148` and executable SHA-256
`3de3086d924e38893c31583f47309f3345733364956e0972287fa1ef7a6966c7`.
All seven runtime files are verified by bytes and modes. The original QAT
model, verified assistant, input bytes, normal MTP, B1, cache-off setting,
production KV grant and output cap 128 remain unchanged.

The M5 sequence is contiguous control, contiguous trace, paged control and
paged trace. Both main repeats have the same 5,418 prompt IDs and first seven
generated IDs. Traces match prompt/output IDs, counts, finish and outcome for
all seven completed same-backend trajectories. Canceled outputs remain prefixes
of their own recovery outputs. Each control preserves its historical backend
trajectory. The earlier [unsupported diagnostic failure](2026-09-06-gemma-qat-logit-capability.md)
is retained separately.

## Confirmed selected decision

Both traces capture request 2, output index/base 7, column 0, seed 529, cache
offset 5424 and phase `rectangular_verify`. Each has verification width 2,
draft depth 1, an empty draft prefix, one confirmed record, no omitted records
and finite FP32 logits. The actual emitted token equals the recorded target
and argmax. The differing accepted-draft counts describe what happened after
the selected decision; they do not invalidate the shared selected prefix.

| Observation | Contiguous | Paged |
|---|---:|---:|
| Logit for candidate 42392 | 26.82098388671875 | 26.719120025634766 |
| Logit for candidate 62203 | 26.667043685913086 | 26.870786666870117 |
| Selected token | 42392 | 62203 |
| Accepted drafts | 0 | 1 |
| Confirmed width | 1 | 2 |
| Main output length, both repeats | 61 | 38 |

The original FP32 bit patterns, top-two IDs, verification context and complete
token trajectories are archived. Candidate ordering agrees with the actual
selected token in both backends. The strict backend comparator retains five
error entries covering the main repeats, tenant baseline and cancellation
donor/recovery outputs.

No attention Q/K/V metadata or common operator input was measured in this
experiment. The [Qwen3.6 packet finding](2026-09-06-qwen36-owner0-packets.md)
therefore cannot explain Gemma's difference by itself. Model-quality,
long-context, MTP/lifecycle and repeated performance acceptance remain open.
Diagnostic timing is not performance evidence.

## Validation and retained evidence

All four native/wrapper executions exit 0. Fourteen local CPU checks cover the
unchanged strict context oracle and successor binding, and eleven unchanged
wrapper tests pass on M5. Fresh readiness and source/runtime/model/assistant
checks precede every model cell. Final postflight has no owned jobs, GPU
32.174 degrees C, load1 1.217 and 351,206,023,168 free bytes.

The [manifest](evidence/gemma-qat-actual-logits-2026-09-06/manifest.json) and
[archive](evidence/gemma-qat-actual-logits-2026-09-06/payloads.tar.gz) retain
162 payloads: raw cells, strict failure, analyses, exact inputs and helpers,
runtime/source/graph identities, staging receipts and independent reviews.
Runtime executables, resources, weights and key material are excluded.

Manifest SHA-256: `9ec9d1424cd471cf9c6cacb758e62bab02dd3f7a03230144002de21cd614553e`.
Archive SHA-256: `a589bec50e8e29ef63042e1a34ac0df9c3dd55af175cbddbf4641b1932145ce1`
(1,014,506 bytes).
