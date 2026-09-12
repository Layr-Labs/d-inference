# Qwen3.5 35B contiguous SSD reference

> Last updated: 2026-09-05 · commit `ac1dc301c`

The exact fleet Qwen3.5 35B artifact passed one normal-MTP, B1 cache-off versus encrypted SSD comparison on the dedicated M5 Max, after the Qwen3.6 reference. All eight paired requests matched across 645 generated token IDs. This is a contiguous-backend reference for the 0.9.0 paged work, using explicit ephemeral test keys.

## Measured behavior

| Request | Cache-off TTFT | SSD TTFT | Tokens saved |
|---|---:|---:|---:|
| First 5,523-token prompt | 1.397245 s | 1.293163 s | 0 |
| Exact repeat | 1.270425 s | 0.411429 s | 4,096 |
| 32-token decode control | 0.038428 s | 0.038371 s | 0 |

The repeat was 67.61% faster in this single ordered pair. These are individual observations, not medians or a general cold-path improvement claim. The 256-token decode control measured 141.09 versus 162.07 tokens/s; one run with the adaptive MTP controller does not establish a decode improvement.

The repeat staged in 44.050 ms and read 165,140,982 bytes. Its provider staging lease peaked at 220,770,300 bytes, which is not total process or model memory. The donor wrote two checkpoint files totaling 279,861,151 bytes, with 73.259 ms of recorded write work and a 75.479 ms last-token-to-completion tail. The repeat added no writes or donation reread and had a 0.0517 ms completion tail.

Every completed measured request reported zero outstanding staging bytes, zero resident-bank budget, and `memory_cache_enabled=false`. Native MLX active/cache/peak counters and host telemetry are preserved separately. Zero idle payload ownership does not imply that allocator cache or RSS returns to zero. GPU temperature samples ranged from 25.16–65.34°C in the cache-off arm and 31.33–62.66°C in the SSD arm. The OS can cache encrypted file reads; this is not a cold physical-SSD throughput measurement.

## Exactness and scope

The [independent verification](evidence/qwen35-contiguous-ssd-2026-09-05/verification.json) compares prompt IDs, generated IDs, decoded text, token counts, and finish reasons for three main requests, three tenant checks, a five-token cancellation, and its 64-token recovery. Tenant A produced a miss then a hit, tenant B stayed cold, and the cancelled donor did not make recovery warm. All eight comparisons pass; the [comparator verdict](evidence/qwen35-contiguous-ssd-2026-09-05/comparator-verdict.json) displays the three main rows.

The production slot factory resolved `contiguous` without fallback, active rectangular Qwen MTP, and `ssd_complete`. The direct harness exercises actual slot construction and SSD staging before raw engine events. It does not cover HTTP or bridge request admission, B2/B4, paged execution, the later request-date renderer, tools/vision, or production-key reuse after a fresh process restart. No model template or identity gate was bypassed.

## Artifact and reproduction

The model is `qwen3.5-35b-a3b`, from `EigenLabs/Qwen3.5-35B-A3B-MLX-VL-4bit-g64` at revision `8964653177a21be79662d51e69fe6a2263ffabb3`. All 14 files, including the separate MTP payload, total 20,893,747,852 bytes and match fleet aggregate SHA-256 `95811153b3bb2ed78bf44b3248b07b52fce637706107de8b0fddf21796ade01c`.

The public catalog's hub revision `59d61f3ce65a6d9863b86d2e96597125219dc754` was stale and did not resolve. The selected current hub revision matches every fleet-file size and digest; both the [hub comparison](evidence/qwen35-contiguous-ssd-2026-09-05/inventory/qwen35-fleet-hub-comparison.json.gz) and [complete downloaded-file verification](evidence/qwen35-contiguous-ssd-2026-09-05/inventory/qwen35-download-verification.json.gz) are retained. Downloads finished before the measured arms.

Both arms use the same immutable engine as the [Qwen3.6 reference](2026-09-05-qwen36-contiguous-ssd-reference.md): parent `ac1dc301c7b15b7d8f0b7bb18cf3d70e93157f75`, native `b5d6c922bd7eec682eb1997c4868befe4efd02ee`, engine SHA-256 `44e5126098dc2d39a79371c8b57e1a476017fb9f26ae79e8d0140bbd401a73a8`, and pinned metallib SHA-256 `4ffbbac48a99b495916c3fa0921ce813eb554de1a09aff408d9b5a5a8053e6b0`. It uses the then-current normalization v2/renderer v1. All 14 remote artifact files were [rehashed after this run](evidence/qwen35-contiguous-ssd-2026-09-05/artifact-verification.json); the shared source, build logs, and runner are archived once with the Qwen3.6 evidence.

The [evidence manifest](evidence/qwen35-contiguous-ssd-2026-09-05/manifest.json) binds the complete reports, telemetry, metadata/logs, exact input, comparison source/verdict, and model verification, with stored and decompressed sizes and hashes. Reproduce with the archived runner and engine, cache-off then cache-on:

```sh
python3 run_radix_engine.py --binary /artifact/radix-engine \
  --model-directory /models/qwen35-pinned --input /input.json \
  --output /results/off --cache off --mtp on \
  --kv-backend contiguous --cache-mode ssd --key-mode ephemeral
python3 run_radix_engine.py --binary /artifact/radix-engine \
  --model-directory /models/qwen35-pinned --input /input.json \
  --output /results/on --cache on --mtp on \
  --kv-backend contiguous --cache-mode ssd --key-mode ephemeral
python3 comparison-tool.py --expect-cache-hits \
  /results/off/report.json /results/on/report.json
```

The host has 128 GiB RAM; the engine grant was 16 GiB. Normal persistent-key process restart remains unproven on this unsigned benchmark host. The earlier [MoE checkpoint prerequisite](2026-09-05-qwen-moe-checkpoint-prerequisite.md) records the separate native/provider fixture coverage.
