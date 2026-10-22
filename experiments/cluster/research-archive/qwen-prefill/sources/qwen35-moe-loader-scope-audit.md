The registered `qwen3.5-35b-a3b` text tensors fit the implemented two-rank FFN and full partition geometry in an offline metadata audit. No unsupported text tensor shape, dtype or quantization policy was found. This does **not** establish that the real weights load or execute correctly.

Artifact: `v2/qwen3.5-35b-a3b--f1f11460a4d1/2026-08-25-r1`; declared aggregate `95811153b3bb2ed78bf44b3248b07b52fce637706107de8b0fddf21796ade01c`. Config, generation config and index bytes were checked against their saved manifest hashes. Safetensors headers were previously fetched as bounded HTTP ranges; the full weight contents have never been downloaded or verified here.

| Count | Stored source | Canonical runtime |
|---|---:|---:|
| Text tensors | 1,757 | 1,637 |
| Routed gate/up tensors | 240 | 120 fused |
| All routed expert tensors | 360 | 240 |
| Quantized text modules | 512 | 472 |

The complete artifact contains 2,136 tensors. The MoE text wrapper discards 333 vision tensors (893,142,496 bytes) and, with MTP disabled, 46 MTP tensors (475,125,888 bytes). Full manifest verification still reads every registered file.

| Tensor payload | Bytes |
|---|---:|
| All retained text | 19,498,262,656 |
| All FFN, including routing/shared gates | 18,202,014,720 |
| Sharded routed + shared FFN | 18,190,172,160 |
| Replicated router, all 40 layers | 11,796,480 |
| Replicated shared gate, all 40 layers | 46,080 |
| FFN data selected per rank | 9,106,928,640 |
| Total per rank, FFN plan | 10,403,176,576 |
| Total per rank, full plan | 10,041,292,096 |

These are stored tensor bytes, not process peak memory. Both ranks have equal payloads. The full plan additionally halves 570,414,720 GDN bytes and 153,354,240 attention bytes; their complete per-head norm vectors remain replicated.

The constructor must use `Qwen35MoEModel` for root `qwen3_5_moe`, preserve 256 experts/top-8 global routing, and halve both 512-wide FFNs to 256 without inventing `intermediate_size`. Each stored routed gate/up triplet has matching U32 packed weights and BF16 scales/offsets. The reader selects rows from both halves, then concatenates along axis 1. All policies are affine W4/G64 with no overrides. All 30 convolutions already use converted `[8192,4,1]` storage, so the singleton sanitizer needs no cross-tensor norm shift. F32 `A_log` remains F32; all other floating text parameters are BF16.

Runtime key equality, full-weight hashes, actual artifact inference, numerical qualification, CBv2, vision/MTP behavior and multi-host throughput remain unverified. Detailed reproducible counts, source hashes and exclusions are in `qwen35-moe-loader-scope-audit.json`; generator: `models/audit_qwen35_moe_scope.py`.
