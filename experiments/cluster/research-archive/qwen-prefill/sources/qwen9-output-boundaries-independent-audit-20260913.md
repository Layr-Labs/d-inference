# Real Qwen3.5-9B output-boundary audit

All six saved executions and their artifact/source identities validate. Independent CPU replay reproduces all six pairwise comparisons exactly from raw JSON logits: **24 rows, 5,959,680 compared values, no argmax disagreement**. None of the six pairs passes the declared strict diagnostic gate. This is bounded numerical evidence, not throughput or model-quality qualification.

The [audit receipt](qwen9-output-boundaries-independent-audit-20260913.json), [CPU replay](audit-qwen9-output-boundaries.py) and [log](qwen9-output-boundaries-independent-audit-20260913.log) accompany the original [run receipt](runs/qwen9-output-boundaries-20260913/receipt.json).

## Identity and workload

- Rehashed all 12 registered model files, totaling **6,113,952,230 bytes**; reconstructed aggregate `127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b` matches the declared artifact. Saved and current manifest bytes match.
- Verified every archived source entry (**139 files**), all five bundle files in the parent bundle and each of four staged bundles, launcher/native outputs, specs and rank evidence. Executable source files still match the snapshot; only three documentation files have changed.
- The saved and current release binary both hash to `74ab08e0d55dbb00b7f5603ec7b686ef7dab2021fcdc790bc816d29c03b3fcb1`. Bundle manifest: `00311b23c24f61e6fab30ae8d8d8dd67c05db101a913ed4c6e4e2ff73ea55581`. This comparison is not a complete reproducible-build attestation.
- The four ordinary/CBv2 controls use the same actual 96-token prose prefix, chunk size 32, four outputs, no warmup, one measured execution, real dense Qwen weights, BF16 activation/metadata policy, and MTP disabled. All are solo, unpartitioned, transport `none`. The first ordinary control is greedy; subsequent controls consume its three teacher tokens `[4087, 13, 271]`. All four outputs' argmax IDs agree: `[4087, 13, 271, 1206]`.
- The two standalone narrowing checks use the same prefix at 65 and 96 tokens, ending in chunks of one and 32 tokens respectively. Their source explicitly retains the same captured ordinary hidden tensor and actual final norm/head modules for every branch.

## Two distinct numerical effects

| Comparison | Maximum absolute error | Maximum row relative RMS |
|---|---:|---:|
| Ordinary native → CBv2 native | 0.125 | 0.00215441019 |
| Ordinary native → CBv2 FFN F32 | 0.1875 | 0.01272135913 |
| Ordinary native → CBv2 attention+FFN F32 | 0.203125 | 0.01412320609 |
| CBv2 native → CBv2 FFN F32 | 0.1875 | 0.01265845163 |
| CBv2 native → CBv2 attention+FFN F32 | 0.203125 | 0.01412320609 |
| CBv2 FFN F32 → CBv2 attention+FFN F32 | 0.15625 | 0.01270904240 |

The native path comparison differs only on the first output row; its three teacher decode rows are bit-exact. For the 96-token same-hidden diagnostic, the two normalized final rows are bit-exact, while applying the actual quantized head over the full 32-row tensor versus one row changes **100,298 of 248,320 logits**. Maximum absolute error is 0.125. Recomputed full-head logits exactly match the original ordinary capture, and narrowing before versus after the norm produces the same narrowed head result. The one-row tail at 65 tokens is exact across all branches.

CPU reconstruction of logical BF16 bytes binds the 96-token diagnostic's ordinary output to the independent ordinary control's first row (`f41545be81b241a472f433ccd2aca98b9561402253ef22a8b95c8c76a2172be9`) and both narrowed outputs to the independent CBv2-native first row (`e9a274e7d557a1fd4e0e86a552bd6541211917ae8f57097611bb0940e4324745`). The actual norm weight and head weight/scales/biases were separately rehashed directly from safetensors and match both diagnostics. This demonstrates head-shape sensitivity sufficient to reproduce the observed first-row gap. It does not inspect CBv2 hidden/cache equality or isolate a unique internal Metal kernel cause.

The wider policies produce changes on **all four rows**, including comparisons that hold the CBv2 path fixed. This is departure from the native numerical policy, separate from final head narrowing. A matched solo/TP benefit for a wider policy would therefore not establish native-policy equivalence. The declared gate requires every row's absolute error below 0.001, relative RMS below 0.0001 and equal argmax. Only the three exact native-path decode rows pass; all six complete pairs fail. The four matching output IDs are limited to this fixed-history sample.

## Memory and throughput interpretation

| Solo control | Peak active MLX bytes | GiB |
|---|---:|---:|
| Ordinary native | 5,265,031,082 | 4.903 |
| CBv2 native | 5,283,110,656 | 4.920 |
| CBv2 FFN F32 | 5,519,546,102 | 5.140 |
| CBv2 attention+FFN F32 | 5,609,991,782 | 5.225 |

`Benchmark.execute` resets MLX's peak after loading and before request-session creation. Subsequent allocator accounting includes resident loaded model buffers plus active state/workspace and MLX capture allocations, including lazy precision casts evaluated during the request. It excludes the earlier loading/construction peak, free allocator cache, Swift/Python host arrays and JSON, and process/OS memory. The reported peak is not incremental request memory or whole-process peak. The two standalone diagnostics expose no peak measurement.

All four native solo reports have `throughputMeasurementValid: true` and `correctnessOnly: false`; these describe the native execution mode, not acceptance of this experiment as a performance benchmark. Every launcher records `hardware_throughput_candidate: false`, and the enclosing receipt explicitly sets `correctness_capture_only: true` and `throughput_qualification: false`. One prompt, no warmup, four outputs and correctness captures provide no sustained TPS, distributed speedup or hardware qualification claim. No GPU/model execution, network operation or repository edit occurred during this audit.
