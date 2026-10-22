# Current Qwen MTP and TP evidence — 2026-09-20

## MTP functionality

The model library already implements a real inline Qwen assistant in `libs/mlx-swift-lm/Libraries/MLXLLM/Models/Qwen35MTP.swift`: selected inline head loading, shared actual target norm/head, request-owned KV/history, proposal, finalization, discard and release. CBv2 has speculative planning, serial target verification, accepted-prefix output handling and assistant finalization. `CBv2QwenMTPIntegrationTests`, `Qwen35InlineMTPLoaderTests`, `Qwen35MTPDraftTrimTests` and `Qwen35MTPTopTwoTests` exercise those library paths. This is distinct from the distributed resident pipeline, whose ordinary Plan, source, capability and request agreement remain MTP-off.

The distributed evidence is narrower:

| Retained evidence | What actually passed | What it did not establish |
|---|---|---|
| `qwen-mtp-selected-load-physical-20260915/physical-1/root-result-review.json` | Registered 9B final stage: 809 target tensors/3,979,190,464 B plus 31 head tensors and 3 input-embedding replicas/709,010,432 B. Actual MLX active 4,688,206,698 B; after release 3,656 B/cache0; model/assistant/file owners released. | No forward, request state or collective. |
| `qwen-resident-mtp-probe-clean-rerun-20260915/physical-1/root-review.json` | Real two-rank cut4 P32/C16/O2: target IDs 2018,6165; actual draft 6165; assistant frontier31→32; target frontier33; original owner cleanup and empty journals. | Draft was not consumed. No accepted-prefix or full-reference numerical/performance qualification. |
| `qwen-mtp-target-verification-physical-20260915/root-review.json` | Seven native-array transaction/retirement cases including keep0/1/2 and progressive stop/continue. | Fabricated arrays, no model or bilateral wire. |
| `qwen-mtp-target-session-supervisor-v2-20260915/root-physical-review.json` | Fifteen tiny real-model Session cases, maximum logit difference0, child/group/journal retired, min actual free11,736,547,328 B, AC/zero swap/pressure1. | No registered checkpoint, actual assistant proposal or bilateral wire. |

The new successor implements the previously missing repeated real assistant finalizer/history and bilateral prefix/publication bridge. It still needs actual compile, native regression and real registered off/on comparison. It uses two serial target forwards per depth-one round; it is a correctness foundation, not an optimized batch-verification or speed result.

## Path to 27B

`artifact-mtp-metadata.json` comes only from retained configuration bytes. Both registered 9B and 27B describe one included inline Qwen MTP head, affine4bit/group64 and shared target embeddings/head. 27B has H5120, 64 target layers and FFN17408, versus H4096/32/12288 for9B.

The current distributed MTP placement/materializer/resource authority is explicitly registered9B/cut4 and binds 709,010,432 additional bytes. The old request allowance is likewise9B-only. Running27B therefore needs its own exact source-aware selected head/embedding map, constructor/layout equality, parameter ownership and allocator-aware assistant/request budget, composed with the already qualified ordinary27B loader/owner. It cannot be enabled by replacing a model name or relaxing the9B byte guard. Next sequence is actual27B selected load/release on48GB, real proposal at a feasible cut, then the same accepted bridge with fresh full reference and per-rank admission. No27B MTP permission or payload validation is added here.

## Tensor parallelism is a separate path

`experiments/cluster/inference/Sources/ClusterInference/QwenPartitionPlan.swift`, `AttentionPartition.swift`, `GDNPartition.swift`, the sharding/projection wrappers and `FeedForwardReduction.swift` implement actual selected tensor partitions and reductions. FFN mode splits intermediate channels; full mode also partitions attention/GDN heads and input projections. Embedding/head replication and quantized operator geometry differ from whole-layer pipeline. Keeping all MoE experts while splitting their intermediate channels is not expert parallelism.

`REAL_QWEN_TP_VALIDATION.md` records real registered9B local two-process FFN/full TP with identical peer logits but failures against matched solo. All8 M4 Max and16 M4 Pro matched rows fail the unchanged max-absolute<0.001, relative-RMS<0.0001 and equal-argmax gate. On M4 Pro, worst relative RMS is0.01586730664 FFN/native and0.01633654258 full/native; both have max absolute0.1875 and4/4 equal argmax. Both-wide gives0.01572166050 FFN and0.01375166936 full, still max0.1875, with3/4 argmax agreement; the first token becomes10926 versus4087. These are fixed teacher-input diagnostics, not free-running quality evaluation, between-Mac qualification or27B TP evidence.

`QWEN_GDN_ARITHMETIC_VALIDATION.md` isolates one first recurrent projection: full N12352 versus selected N6176 at M32/K4096 gives125,801/395,264 differing values, max0.25 and relative RMS0.002689177293. Padding selected affine-zero rows back to full width then cropping gives exact native values for this operator. FP32 full versus ranks nearly agrees (max0.00009155273438, relative RMS0.000000700219207), but FP32 changes104,168 original native values and still leaves98 differences after BF16 cast. The pinned dispatch predicts split-K1 versus2; it was not traced, and padding changes more than dispatch. This establishes output-width sensitivity, not a proof that reassociation explains every whole-model failure or that sharding is otherwise correct.

No threshold is changed here. Pipeline correctness does not qualify TP. Practical TP needs isolated operator/partition inverses and matched strict diagnostics first; a distinct arithmetic mode would additionally require independent held-out likelihood/quality and free-running task evaluation against the intended full-model baseline before any quality or speed claim. A separate requested Qwen/Gemma TP evidence audit will retain the exact failed gates.

`audit-inputs.json` pins the small receipts/reports used above. No native or payload was re-read.
