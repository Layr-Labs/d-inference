The registered Qwen3.5-9B is complete and usable for the next bounded local solo experiment. I rehashed all 12 manifest files with `runtime.artifacts.verify_model`; all sizes, per-file hashes, and aggregate match the cached public registry. No inference was run.

| Artifact | Local path | Availability | Weight-file bytes | Text parameter payload |
|---|---|---|---:|---:|
| Qwen3.5-9B | `/Users/developer/DarkbloomDev/models/Qwen3.5-9B` | Complete; aggregate verified | 6,087,105,488 | 5,038,041,600 (4.692GiB) |
| Qwen3.8-27B | `/Users/developer/DarkbloomDev/models/Qwen3.8-27B` | Metadata only; 11 manifest files absent | 16,293,475,586 required | 15,132,802,048 (14.094GiB), metadata estimate |

9B aggregate: `127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b`. Config SHA256: `c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423`. Total registered artifact including tokenizer/config files is 6,113,952,230B. Model type is `qwen3_5` / `qwen3_5_text`; dense H4096/I12288/L32, 24GDN+8attention layers, attention Q16/KV4/D256, GDN K16/V32/D128. Affine W4/G64 packed U32 projections use BF16 scales/biases; the 24 A_log vectors are F32. Exact shapes/dtypes of all 927 text tensors agree with the source geometry; converted convolution `[channel,4,1]` requires no raw-HF norm shift. Text loading discards vision/MTP tensors; all manifest files still must exist for verification.

27B aggregate: `bbd0e0adcfe74e095073fefd0b9e116e4311d606ad9989cf81f8175e8ac18463`. Config SHA256: `4691da94a1b4ef415aad112ec46abebd33f8a41ad07380e486c0526eb945c1ff`. The three target shards, MTP shard, tokenizer/template, and preprocessing files are absent: 16,320,199,553B missing. Config/index/generation config hashes match, but saved HTTP-range headers do not verify absent weight contents. Metadata has dense H5120/I17408/L64, 48GDN+16attention, Q24/KV4/D256, GDN K16/V48/D128; affine W4/G64, U32 plus BF16. All 1,847 text shapes fit existing partition geometry. The catalog's `apple_m5`/`mlx_nax` eligibility remains unchanged. Config `output_gate_type=swish` is not consumed by current Qwen35.swift; its semantic effect needs reference-model verification before claiming real-checkpoint parity.

| Predicted parameter storage | 9B | 27B (not present) |
|---|---:|---:|
| One solo text model | 5.038GB | 15.133GB |
| Two full replicas combined | 10.076GB | 30.266GB |
| Two FFN ranks combined | 7.358GB | 20.640GB |
| Two full-TP ranks combined | 6.183GB | 16.564GB |

The local machine has 36 GiB physical memory. A 9B solo and bounded two-rank/replica correctness workload are plausible fits from these payloads; peak allocation still needs measurement. For 65 prompt + 8 output tokens, source-derived BF16 KV plus F32 GDN state and BF16 convolution history is about54 MB solo for 9B (159 MB for 27B), excluding temporary activations, output tensors, loader staging, process runtime, and OS residency. Ordinary loading reads all 6.087 GB of 9B shards before dropping vision/MTP; its transient memory exceeds retained text payload. At inspection the system reported 44% free memory with significant compression, so payload arithmetic alone is not a launch guarantee. A short first solo run, then sequential controls, is the strongest next step. At vocab 248,320, persistent-worker logit capture supports at most 4 output rows under its 1,048,576-value limit.

Current launcher and native Options explicitly restrict `loopback-test` to synthetic models. Real solo and independent local replicas are supported; same-host real TP requires an explicit implementation/policy change. Existing direct-loader geometry supports the 9B metadata, but actual real loading and partition inference remain untested by this inventory.

Standard HF cache contains complete file sets for different `mlx-community/Qwen3.5-27B-8bit` and `mlx-community/Qwen3.6-27B-4bit` snapshots. Neither has the registered target manifest; symlinks point outside each snapshot, incompatible with the current contained-file verifier. The W8 model is additionally outside the Qwen W4 partition policy. Their bytes were not rehashed and they must not stand in for Qwen3.8-27B. No additional 9B or requested 27B artifact was found in the scoped model directories or standard HF cache. The provider's documented cache is the HF hub; known `.darkbloom` model/cache directories are absent. Credential files and unrelated personal files were not read.

Exact counts, paths, missing-file list, dtype inventory, cache snapshots, and derived state/storage bytes are in `local-registered-model-inventory-20260913.json`. Scope: CPU-only file/header/hash inspection, no downloads, model construction, GPU, SSH, or production-state writes.

Usable offline tokenizer: `/Users/developer/.darkbloom/python/bin/python3` has `tokenizers`, `transformers`, and `jinja2`; the development `.venv` does not. I loaded the verified local `tokenizer.json` with `tokenizers.Tokenizer.from_file` and encoded/decoded a public test sentence with `HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1`. No model imports or network were used. Plain tokenization is verified; chat-template rendering should be bound separately if used.
