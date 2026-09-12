# Qwen3.6 SDPA partial precision: selected operator discriminator

> Last updated: 2026-09-06 · commit `2eebb5412`

On one sealed Qwen3.6 owner0 B1/D256 input, widening native SDPA's two-pass
partial storage from BF16 to FP32 changes 786 of 4,096 output elements and
leaves only one element different from the previously captured paged output.
The baseline reproduces its sealed contiguous capture exactly. This is an
ephemeral operator-level causal discriminator, not Q35/Q36 whole-model
correctness closure or permission to change production arithmetic.

## Actual result

Exactly two fresh `nativeSDPA` processes run, baseline then variant, with a
180-second deadline each. Both evaluate and serialize an 8,192-byte BF16
output of shape `[1,16,1,256]`; both exit zero. No paged operator or model is
executed in this experiment: the paged comparison is an existing capture.

| Check | Baseline | FP32-partial variant |
|---|---:|---:|
| Output differences from sealed contiguous capture | 0 / 4,096 | 786 / 4,096 |
| Output differences from sealed paged capture | 786 / 4,096 | 1 / 4,096 |
| Actual two-pass dispatch records | 1 | 1 |
| Blocks | 128 | 128 |
| Partial elements | 524,288 | 524,288 |
| Partial dtype / bytes | BF16 / 1,048,576 | FP32 / 2,097,152 |
| Q/K/V and final output dtype | BF16 | BF16 |
| Owned and independent group-retirement receipts | complete | complete |

Baseline SHA-256:
`390fe57dded021665191e7fffa0278a39ca44909f399b34128403fb6aa69b78d`.
Variant SHA-256:
`1b5a4d9488fb48f5099c9e58d5f1eee601263e8f635259aca6dff85969cc2cec`.
Paged-capture SHA-256:
`accec5723d4f912aeadaece3119276b49643eed5f7b9f94526f107958abdfa3b`.

The actual stderr traces identify the baseline
`sdpa_vector_2pass_1_bfloat16_t_256_256_nomask_qnt_nc_nosinks_128` and
`sdpa_vector_2pass_2_bfloat16_t_256` functions; the variant identifies their
`sdpa_vector_2pass_fp32partials_` counterparts. Both report QH16/KVH2, QL1,
history 5,585, D256, scale `0x1p-4`, and no mask, sinks or transposed query.
These are not enqueue-only results: the pinned `CBv2AttentionReplay.run`
calls `eval(output)` before copied output serialization
(`libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/CBv2AttentionReplay.swift:137`).
Result descriptors, raw byte hashes, successful terminals and process
identities agree.

## Numerical comparison, not an acceptance threshold

The independent review reproduces Main's analysis exactly using NumPy 2.4.2
and the original-query FP32 reference, with FP64 error aggregation. Original
Q/K/V bytes are read from the existing sealed packet bank, not from a new
model run. All inputs, outputs, logits, weights and reference outputs are
finite.

| Descriptive measure | Baseline | Variant | Paged capture |
|---|---:|---:|---:|
| FP32-reference maximum absolute error | 0.004564166069 | 0.003840804100 | 0.003840804100 |
| FP32-reference RMSE | 0.0004728790761 | 0.0004430570316 | 0.0004430570316 |
| BF16-rounded-reference maximum error | 0.0078125 | 0.00048828125 | 0.00048828125 |
| BF16-rounded-reference RMSE | 0.0004458155729 | 0.000007629394531 | 0.000007629394759 |
| Elements unequal to BF16-rounded reference | 785 | 1 | 2 |

The sole variant-versus-paged difference is flat index 1,179, query head 4,
channel 155: variant `2.384185791015625e-5`, paged capture
`2.396106719970703e-5`, original FP32 reference `2.385427796980366e-5`.
The baseline value there is `5.0067901611328125e-5`. This remaining difference
is retained, not rounded away or converted into a capture-PASS claim.

[INFERENCE] Baseline reproduction, the controlled partial-storage/ABI
intervention and the changed evaluated output support intermediate partial
precision as a material mechanism for this selected operator difference.
Near agreement with the paged capture does not establish identical arithmetic
or explain every downstream model-token difference. No tolerance, quality,
latency or throughput gate is evaluated.

## Source, ABI and compiled-library provenance

Both independent arm builds use parent `5073f696d46adfe98a835e7795633a0ecd50ac3c`,
native `f2d79145e040bbc28c6e0e355a19bc8923a70434`, Swift
`9561227d55a07db29f70a78aadc5d6b5aaeb10bf`, core
`fab0f39f69140393b454c32d6f4bf7a9b32f9dcc`, C wrapper
`d4328f2d8d54d711d5419e07ab9fa2f07b512a48`, and explicitly unused top-level
MLX `0a725e3000edabc4911cde345270ca950bfa152f`.

The working core is base plus declared overlays, not a falsely clean fab0
checkout. Baseline adds the common dispatch trace. Variant also changes the
host partial allocation to FP32, Metal partial writers/readers to `float`,
and matching two-pass function aliases; final output remains BF16. The three
patches and per-arm source/artifact manifests are retained. No experimental
patch is applied to the primary source tree or its dependencies.

Actual `MTLLibrary.functionNames` and device queries report 17,326 functions
per library, including exactly 39 matching two-pass and 18 unchanged one-pass
SDPA entries, without mixed aliases. Both report `applegpu_g17s`, selecting
128 blocks for this input. Inventory identities bind each arm's own metallib
and query helper. Fifteen distinct successful build/inventory steps are
retained, including compilation of the inventory helper.

Final adapter manifest:
`12cd0ce5eec6cf252a5d8cdc58c6a30e5756fa17b5c30cde7dbfc93c222367d8`.
Full M5 raw-proof manifest, 2,137 entries / 468,692 bytes:
`900f7cc8a895bd3fcf6372a7f21a89258de9bc14b316bd1f8cad278534e3dfed`.

Main ran the final adapter's complete raw-evidence/Git-base verification on
M5 before both operators. This independent result review does **not** repeat
that remote audit. It verifies the collected frozen manifest and approval
binding, all 51 collected raw files, completed-arm seals, trace/output and
cleanup identities, declared source overlays, compiled inventories, and 47
retained build payloads against the raw-proof manifest. The full remote build
tree is not copied into this capsule. Runtime reviews preserve the
arm-local-loading basis; distinct variant dispatch names and evaluated output
provide additional runtime evidence, not a new loader probe.

## Lifecycle and preserved failures

The fresh exclusive handoff encloses both invocations. Native stdout and
stderr remain separate; caller pings are received rather than self-renewed.
Both owner and independent fallback receipts identify the same native
PID/birth/PGID and prove retirement; the variant begins after baseline
completion. Recorded postflights and collection observation show no owned
or unexpected jobs. These are historical observations, not a fresh M5 probe.

The [failure ledger](evidence/qwen36-sdpa-partials-2026-09-06/preserved-failures.json)
preserves three plumbing events:

- Initial baseline packaging incorrectly expected
  `swift-crypto_Crypto.bundle/PrivacyInfo.xcprivacy`. Its original traceback
  and attempt1 receipts remain; corrected packaging uses actual SwiftPM
  resources rather than fabricating the missing bundle.
- Staging refused stale adapter approval as the manifest moved from
  `0d48757a...` through `eee934df...` to the reviewed `12cd0ce5...` revision.
  This event is retained as Main/user-reported provenance with the guard's
  source hash; rejected-call stdout/stderr was not separately present in the
  supplied collection and is not reconstructed.
- Premature binding preparation failed to import `common` before successful
  final staging. The original failure and successful retry receipts remain.

These failures do not count as extra operator executions. The earlier P1
ownership/proof repairs and final dependency-proof compatibility re-review
remain documented; final adapter CPU logs record 41 normal and 41 optimized
tests passing. This review performs no SSH, build, operator or model run.

## Frozen bank and limits

The [manifest](evidence/qwen36-sdpa-partials-2026-09-06/manifest.json),
[capsule](evidence/qwen36-sdpa-partials-2026-09-06/payloads.tar.gz) and
[independent review](evidence/qwen36-sdpa-partials-2026-09-06/independent-review.json)
retain 132 regular payloads: new patches, source/build metadata, raw graphs
and selected logs, both actual output/receipt trees, analysis and failures.
The archive is 2,199,850 bytes; uncompressed payloads total 9,633,459 bytes.
All archive members are rehashed, and executable/metallib/AIR payloads,
full source copies, keys, certificates and weights are excluded.

Manifest SHA-256:
`0c563d66fc7dc4632881a1b78b843ddb970573bf9046a9bdc5d04bc001955e3a`.
Archive SHA-256:
`1faedb025b7bcd0903a538533da8591fe7b2b8a01695d62d1c0bdcd5c56031a2`.

The approximately 11 MiB common Q/K/V remain in the existing
[sealed packet bank](evidence/qwen36-owner0-packets-2026-09-06/manifest.json)
and are referenced by exact archive/member hashes, not duplicated. Context:
[original packets](2026-09-06-qwen36-owner0-packets.md) and
[same-input operator replay](2026-09-06-qwen36-owner0-operator-replay.md).

This closes a selected operator discriminator only. Actual Q35/Q36 model
correctness, token trajectories, other shapes and GQA specializations,
MTP/lifecycle behavior, broader numerical quality and repeated serving
performance remain open. It neither changes the global source nor authorizes
a production FP32-partial policy.
