# Registered Qwen3.5-9B local full-TP audit

All four logical runs, six rank reports, artifact identities, reconstructed storage commitments and saved comparisons pass independent CPU verification. Both full-TP runs have exact peer logits. **Neither matched solo/TP comparison passes the unchanged numerical gate.** The wider policy lowers relative RMS but changes the first selected token.

Evidence: [independent JSON audit](runs/qwen9-local-tp-full-20260913/independent-cpu-audit.json), [replay script](audit-qwen9-local-tp.py), [audit log](qwen9-local-tp-full-independent-audit-20260913.log), [original receipt](runs/qwen9-local-tp-full-20260913/receipt.json). The audit ran only after root confirmed all native processes terminal; it launched no native/model/GPU workload.

## What executed and what was verified

Native and both-wide arithmetic each ran one solo control and one two-process **full** partition on the same Mac. Every run used CBv2 contiguous execution, the same verified 96-token prose prefix, chunks of 32, four outputs, teacher inputs `[4087, 13, 271]`, BF16 activations/metadata and MTP disabled. There were no warmups and one measured repetition. The local-correctness opt-in and expected aggregate were forwarded only to the two TP runs. FFN-only execution was excluded after its initial memory admission estimate failed; its performance or numerical behavior was not tested here.

All 12 model files were rehashed, totaling **6,113,952,230 bytes**, matching aggregate `127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b`. Config SHA-256 is `c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423`. All **146 archived source entries**, bundle copies, input/evidence hashes and current executable source bytes agree. Tested and current native binary: `26fe9543a617d97309c581bfdf80fc929b85fb2c652d9cd560f61191d1794770`.

An independent interpretation of the actual safetensor headers and explicit FFN, attention and segmented GDN axes reconstructs the **entire shared storage commitment**, including source-selection and rank-layout hashes. It matches every real direct-load receipt: 927 canonical text tensors, 5,038,041,600 source bytes, 2,717,908,992 FFN bytes, 3,893,236,224 full-sharded source bytes, **3,091,423,488 selected bytes per rank**, and largest selected host tensor **508,559,360 bytes**. This audit reads actual metadata and verifies artifact content; it does not instantiate a model.

Both new solo outputs are bit-exact with their prior 9B controls (`cbv2-native` and `cbv2-attention-ffn-float32`). Default behavior and the corresponding wider solo policy therefore reproduce across the opt-in implementation change. Six rank captures contain 24 rows / **5,959,680 logits**. Each full rank records 384 model-reduction hooks over six forwards; the two TP runs total **1,536 hooks**. These are graph-hook counts, not independently timed transport completions.

## Matched-policy numerical result

Metrics are recomputed from IEEE Float32 values reconstructed from native JSON, including all 248,320 logits in each row. The gate requires maximum absolute error `<0.001`, relative RMS `<0.0001`, and equal argmax on every row.

| Output row | Native relative RMS | Both-wide relative RMS | Metric reduction | Both-wide argmax matches solo |
|---|---:|---:|---:|---|
| 0 | 0.01396574061 | 0.01234682770 | 11.59% | No |
| 1 | 0.01633654258 | 0.01375166936 | 15.82% | Yes |
| 2 | 0.01206828963 | 0.01099840957 | 8.87% | Yes |
| 3 | 0.01157325911 | 0.00938585643 | 18.90% | Yes |

Both pairs fail all four rows. Worst relative RMS decreases **15.82%**, from 0.01633654258 to 0.01375166936. Worst absolute error remains **0.1875** in both policies; row two's absolute maximum worsens from 0.140625 to 0.1875. Lower relative RMS is not a correctness or quality qualification.

Native solo/full and both-wide solo all select `[4087, 13, 271, 1206]`. Both-wide full selects `[10926, 13, 271, 1206]` on both peers. On row zero, the first three executions tie IDs 4087 and 10926 at 19.875, selecting lower ID 4087. Both-wide full leaves 10926 at 19.875 and lowers 4087 to 19.75, one BF16 step. The fixed teacher then supplies 4087 regardless of that first output; later matching choices do not demonstrate free-running continuation.

Separate native→both-wide comparisons change all four rows in both solo and full modes. The solo policy departure reaches relative RMS 0.01412320609; full-mode departure reaches 0.01245953711 and includes the same first-token change. The matched TP comparisons hold CBv2's output schedule fixed. The previously isolated ordinary/CBv2 vocabulary-head shape effect does not explain away these TP errors.

## Memory and scope

| Run | Execution peak active MLX bytes | Peak sampled RSS of observed owned processes |
|---|---:|---:|
| Native solo | 5,283,110,656 | 3,704,012,800 |
| Native full, ranks 0 / 1 | 3,254,154,522 / 3,254,105,370 | 5,697,880,064 combined |
| Both-wide solo | 5,609,991,782 | 5,875,892,224 |
| Both-wide full, ranks 0 / 1 | 3,414,376,730 / 3,414,376,730 | 5,862,719,488 combined |

The separate startup/loading observation is identical for all four TP ranks: active MLX **3,091,429,648**, free cached MLX **11,794**, and peak active MLX since process start **3,091,440,148 bytes**. Execution resets its peak after loading, so these loading observations and request peaks have different windows. MLX active bytes exclude Foundation host copies, free cache and process/OS memory. Sampled RSS is a different measurement and can miss short transients; neither column is a whole-system hard memory bound or a loading-headroom guarantee.

Recorded system pressure level is 2 in all samples. Swap use increases by **408,871,240 bytes** across native full and **123,543,224 bytes** across both-wide full, below the driver's 1 GiB refusal threshold; solo deltas are zero. Do not describe these runs as swap-free. Saved cleanup records confirm all observed owned processes exited and launchers were reaped; the audit does not infer arbitrary historical PID identity from a later process listing.

The enclosing receipt sets hardware-throughput, numerical and model-quality qualification to false. Native loopback reports retain correctness-only/non-performance flags. These results establish verified real-artifact local execution, exact peer agreement and reproducible numerical failures. They establish no physical two-machine correctness, RDMA behavior, production scheduling, 27B qualification or M3 Ultra TPS result.
