# Qwen3.6 35B contiguous SSD reference

> Last updated: 2026-09-05 · commit `ac1dc301c`

The exact fleet Qwen3.6 35B artifact passed one normal-MTP, B1 cache-off versus encrypted SSD comparison on the dedicated M5 Max. All eight paired request outputs matched across 645 generated token IDs; the repeated 5,523-token prompt reused 4,096 tokens. This is a contiguous-backend reference for the 0.9.0 paged work, with explicit ephemeral test keys.

## Measured behavior

| Request | Cache-off TTFT | SSD TTFT | Tokens saved | SSD disposition |
|---|---:|---:|---:|---|
| First 5,523-token prompt | 2.178647 s | 1.361440 s | 0 | Miss |
| Exact repeat | 1.272830 s | 0.411859 s | 4,096 | Hit |
| 32-token decode control | 0.098299 s | 0.037929 s | 0 | Miss |

The repeat was 67.64% faster in this single ordered pair. The earlier cache-off first request was slower than its subsequent uncached repeat, so startup/kernel warming affects the cold observations. These are individual measurements, not medians or a general cold-path improvement claim. Decode control measured 162.99 versus 166.57 tokens/s; this single observation does not establish a decode improvement.

The actual repeat stage took 44.620 ms and read 165,140,982 bytes. The provider staging lease peaked at 220,770,300 bytes. This lease is not total process or model memory. The donor committed two checkpoint files totaling 279,861,151 bytes, with 78.839 ms of recorded write work and 80.932 ms between its last token and completion. The repeat wrote no additional bytes, performed no donation reread, and had a 0.0575 ms completion tail.

All completed measured requests reported zero outstanding staging bytes, zero resident-bank budget, and `memory_cache_enabled=false`. Native MLX active/cache/peak memory and host telemetry are retained separately; zero idle checkpoint ownership does not imply zero allocator cache or an exact return of RSS to the model-only level. Encrypted reads can be served by the operating system file cache, so these timings do not measure cold physical SSD throughput.

## Exactness and isolation

The independent [verification](evidence/qwen36-contiguous-ssd-2026-09-05/verification.json) checks prompt IDs, generated IDs, decoded text, completion counts, and finish reasons for three main requests, three tenant checks, one five-token cancellation, and its 64-token recovery: eight cross-arm comparisons and 645 generated IDs. Tenant A showed a miss then a hit; tenant B remained cold. The cancelled donor did not publish a reusable checkpoint, and recovery remained a miss. The [comparator verdict](evidence/qwen36-contiguous-ssd-2026-09-05/comparator-verdict.json) also passes; its compact display lists only the three main rows.

The production slot factory selected `contiguous` with no fallback, active rectangular Qwen MTP, and `ssd_complete` in the cache-on arm. The benchmark used the real slot construction and SSD staging before consuming raw engine events. This run does not cover HTTP or bridge request admission, B2/B4, paged execution, final request-date normalization, vision/tools, or production-key reuse after a fresh process restart. No model template or identity gate was bypassed.

## Artifact and reproduction

The exact fleet model is `qwen3.6-35b-a3b-vl-mtp-mxfp8`, from `EigenLabs/Qwen3.6-35B-A3B-MLX-VL-4bit-g64-router8` at revision `73a03825c2226177f3e679210965dba3508cdee8`. All 13 files, totaling 21,308,856,601 bytes, match aggregate SHA-256 `d932e96b00404b0575fff47e2dac8ed113056b3f22d0040c3c8d3f9ef25b09ed`. The final download tail used a local exact HTTP range transfer after the direct M5 download slowed; the complete assembled shard and every fleet file were verified before inference. Qwen3.5 downloading was stopped during both measured arms.

The identical binary in both arms was built from parent `ac1dc301c7b15b7d8f0b7bb18cf3d70e93157f75`, native `b5d6c922bd7eec682eb1997c4868befe4efd02ee`, and MLX `6b0505cc790f512ae49d740b21e13f80802946bd`, with `RADIX_CANDIDATE` and Swift 6.3.2. It preserves the then-current normalization v2/renderer v1. The artifact manifest records all binary, resource, source, and harness hashes; the five harness source files exactly match that parent commit.

| Artifact | SHA-256 |
|---|---|
| Engine | `44e5126098dc2d39a79371c8b57e1a476017fb9f26ae79e8d0140bbd401a73a8` |
| CLI | `dcd221dc51b4e00cc0c1e1eb7ddddfb9898f6f83b7a20f8d884c4bf1b5ae23aa` |
| Pinned metallib | `4ffbbac48a99b495916c3fa0921ce813eb554de1a09aff408d9b5a5a8053e6b0` |

The [evidence manifest](evidence/qwen36-contiguous-ssd-2026-09-05/manifest.json) binds both complete reports, telemetry, run metadata/logs, exact input, comparison tool/verdict, download verification, and build/source manifests. Stored and decompressed sizes and SHA-256 digests were checked independently. Models and compiled binaries remain in the isolated benchmark workspace rather than in Git.

Use the archived runner with the archived engine and input, in cache-off then cache-on order:

```sh
python3 run_radix_engine.py --binary /artifact/radix-engine \
  --model-directory /models/qwen36-pinned --input /input.json \
  --output /results/off --cache off --mtp on \
  --kv-backend contiguous --cache-mode ssd --key-mode ephemeral
python3 run_radix_engine.py --binary /artifact/radix-engine \
  --model-directory /models/qwen36-pinned --input /input.json \
  --output /results/on --cache on --mtp on \
  --kv-backend contiguous --cache-mode ssd --key-mode ephemeral
python3 comparison-tool.py --expect-cache-hits \
  /results/off/report.json /results/on/report.json
```

The M5 Max had 128 GiB physical RAM and used a 16 GiB engine KV grant. Normal persistent-key validation remains unproven on this unsigned benchmark host. The earlier [MoE checkpoint prerequisite](2026-09-05-qwen-moe-checkpoint-prerequisite.md) records the bounded native and provider fixture coverage separately.
