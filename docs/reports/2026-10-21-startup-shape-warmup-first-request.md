# Startup Shape Warmup: First-Request TTFT — 2026-10-21

> Last updated: 2026-10-22

On a cold per-app Metal shader cache, the first ~8K-token request after process start took 4.0-4.4 s on an M3 Ultra without the excluded startup shape warmup and 2.9-3.4 s with it, the same as later requests. A warm cache showed no first-request penalty either way. This record freezes the measurements, method and raw logs behind the summary in [Inference architecture](../architecture/inference.md).

## Results

TTFT of the first ~8K-token request after process start, warmup off → on (`DARKBLOOM_TTFT_SHAPE_WARMUP=0` vs unset):

| Machine | Cache | Gemma 4 QAT (ms) | GPT-OSS 20B (ms) |
|---|---|---|---|
| M3 Ultra | cold, pair 1 | 4401.8 → 2956.7 | 4054.9 → 3352.5 |
| M3 Ultra | cold, pair 2 | 4368.2 → 2934.3 | 4173.6 → 3368.8 |
| M3 Ultra | warm | 2935.0 → 2915.5 | 3350.5 → 3366.0 |
| M5 Ultra (shared) | cold | 3190.7 → 1126.8 | 5276.9 → 1634.6 |

Model IDs are `gemma-4-26b-qat-4bit` and `gpt-oss-20b`.

M3 Ultra details, from [`m3-ultra-summary.txt`](evidence/2026-10-21-startup-shape-warmup/m3-ultra-summary.txt):

| Observation | Gemma 4 QAT | GPT-OSS 20B |
|---|---|---|
| Later requests in the same sessions | 2910-3039 ms | 3346-3439 ms (one 4574 ms outlier, warmup off) |
| Cold `"Hi"` self-test proxy, off → on | 781/781 → 390/400 ms | 1522/1561 → 133/128 ms |
| Cold warmup log | complete 2/2 cells in 5699 and 5744 ms | complete 2/2 cells in 5972 and 6040 ms |
| Cold probe, first/repeat | 1266/106, 1246/105 ms | 1527/87, 1565/88 ms |
| Warm probe outcome (arm D) | skipped in 249 and 268 ms (probe 112/105, 149/99 ms) | skipped in 217 ms (probe 101/87 ms) |
| Listener ready, cold off → on | 10.2/9.0 s → 14.7/14.7 s | 9.0/8.0 s → 14.2/14.2 s |
| Listener ready, warm off → on | 4.3 s → 4.4 s | 4.4 s → 4.3 s |

M5 Ultra cold probes were 2340/69 ms (Gemma) and 2660/54 ms (GPT-OSS); the warmups took 5354 and 7375 ms.

The highest warm first probe seen in the provider GPU test suite on the same day was 443 ms (`qwen3.5-35b-a3b`, repeat 139 ms), below the cold rule in `ModelCalibrationPolicy.shaderCacheLooksCold`.

## Method

- **Cold cache.** Each cold arm wrapped the same `darkbloom` and `mlx.metallib` in a throwaway `.app` with a fresh `CFBundleIdentifier`, which gives the process its own empty per-app Metal shader cache under `$(getconf DARWIN_USER_CACHE_DIR)/<bundle-id>/com.apple.metal`. This stands in for a new install or the first start after a macOS or MLX kernel-source change.
- **Arms.** A: cold, warmup off. B: cold, warmup on. C: B's bundle (now warm), warmup off. D: B's bundle, warmup on. M3 Ultra ran A, B, C, D, then a second cold pair with new bundle IDs in reverse order (B, A), per model.
- **Session.** `darkbloom start --local --model <id>` with private state files, prefix cache off, then a 20 s settle, a streaming `"Hi"` request with `max_tokens=1` as a self-test proxy, then three sequential ~8K-token requests (3 s apart, 16 output tokens). Each prompt starts with a unique nonce, so no prefix is reused. TTFT is client-measured to the first streamed content.
- **M3 Ultra.** Release build of this PR's warmup commit, binary MD5 `af73d71fd626cb4cff39c679bc094120`, `mlx.metallib` MD5 `be39c9c1bab3f06ad53157b873971713`. Each session ran alone under an exclusive GPU lock, and the host reported thermal state nominal at every arm. A `darkbloom benchmark --runtime-generation` smoke after the matrix exited 0 with coherent text for both models.
- **M5 Ultra.** An earlier build that differs from the PR only in a 250 ms cold margin instead of 750 ms; both cold probes clear either margin. The machine was shared: the GPT-OSS arms ran beside one or two other servers at thermal state fair, so the M5 Ultra rows show direction, not a controlled ratio.

## Evidence

Logs and harness are frozen in [`evidence/2026-10-21-startup-shape-warmup/`](evidence/2026-10-21-startup-shape-warmup/):

| File | Contents |
|---|---|
| [`m3-ultra-job.txt`](evidence/2026-10-21-startup-shape-warmup/m3-ultra-job.txt) | Full M3 Ultra job: binary hashes, per-arm ready time, `"Hi"` proxy, per-request TTFT, warmup log lines, smoke |
| [`m3-ultra-summary.txt`](evidence/2026-10-21-startup-shape-warmup/m3-ultra-summary.txt) | One line per M3 Ultra session |
| [`m5-ultra-gemma-AB.txt`](evidence/2026-10-21-startup-shape-warmup/m5-ultra-gemma-AB.txt), [`m5-ultra-gptoss-AB.txt`](evidence/2026-10-21-startup-shape-warmup/m5-ultra-gptoss-AB.txt) | M5 Ultra cold A/B sessions with host load and other-server counts |
| [`harness/`](evidence/2026-10-21-startup-shape-warmup/harness/) | M3 Ultra `job.sh`, `run_arms.sh`, `session.sh`, `make_bundle.sh`, `first_ttft.py`, `hi.py`, `summarize.py` and the smoke prompt, as run (host paths unchanged) |

## Limitations

- Two models, one prompt length (~8K tokens) and one request at a time; no fleet or concurrent-load measurement.
- Cold caches were simulated with fresh bundle IDs, not by a macOS update or MLX kernel-source change.
- The probe rule judges the whole cache from one 128-token shape. A cache holding that shape but not the long or served-width specializations was not measured.
