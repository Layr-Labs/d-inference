# Five-model native KV type probes

> Last updated: 2026-09-05 · commit `825696740`

All five exact fleet artifacts passed the loaded target KV probe on an Apple M5
Max with 128 GiB memory, running macOS 26.5.2. Runs followed the requested order:
Qwen3.6 35B, Qwen3.5 35B, Qwen3.8 27B, GPT-OSS20B, then Gemma4 26B. Each used a
fresh process and the same immutable executable. Model aggregate hashes matched
before and after loading, and each artifact passed its real prompt-contract
identity check.

The [evidence manifest](evidence/five-model-native-kv-probes-2026-09-05/manifest.json)
contains raw reports, commands, process outcomes, telemetry, verification,
hardware metadata and the release artifact manifest. All 21 payload hashes
computed on M5 matched the copied local payloads. The separately retained
[native semantic milestone](2026-09-05-paged-native-types.md) identifies the
source, 109 native cases, 47 provider functions and release build.
The parent independently verified all 31 stored/raw/source payloads, the 21
remote hash matches, and every phase/type observation before banking.

## Actual observations

The probe runs two token-0 prefill positions followed by one decode position
through the actual serving target and fresh `newCacheV2` rows. It records K/V
at the storage boundary after projections and positional transforms. Every
owning layer produced one prefill and one decode observation; K/V types and
shapes agreed in both phases. There were 180 observations across 90 owners.

| Artifact | Owning attention rows | KV heads / head width | Measured K/V dtype |
|---|---:|---|---|
| Qwen3.6 35B MoE | 10 | 2 / 256 | BF16 throughout |
| Qwen3.5 35B MoE | 10 | 2 / 256 | BF16 throughout |
| Qwen3.8 27B | 16 | 4 / 256 | BF16 throughout |
| GPT-OSS20B | 24 | 8 / 64 | Layer 0 BF16; layers 1–23 FP32 |
| Gemma4 26B | 30 | 25 rows: 8 / 256; 5 rows: 2 / 512 | BF16 throughout |

GPT-OSS's later sliding-window layers also use FP32. A table inferred only from
weight dtypes or the full/window distinction would therefore be wrong. The
explicit paged factory consumes these load-time observations instead. Gemma's
full-attention rows exercise width 512, so the small width-64 kernel fixtures
alone cannot establish its paged execution correctness.

The verified aggregates are:

| Model ID | Aggregate SHA-256 |
|---|---|
| `qwen3.6-35b-a3b-vl-mtp-mxfp8` | `d932e96b00404b0575fff47e2dac8ed113056b3f22d0040c3c8d3f9ef25b09ed` |
| `qwen3.5-35b-a3b` | `95811153b3bb2ed78bf44b3248b07b52fce637706107de8b0fddf21796ade01c` |
| `EigenLabs/Qwen3.8-27B-4bit-mtp` | `bbd0e0adcfe74e095073fefd0b9e116e4311d606ad9989cf81f8175e8ac18463` |
| `gpt-oss-20b` | `61bfc04e4016a7fa487eb10e29f79360047e302487229f298da3681984aec512` |
| `gemma-4-26b` | `a4722b6020adb1894c700b45ddcd58bc0e0f033abe7139f86cbbbfe60cba4eb6` |

Exact prompt-contract IDs, model directories, layer indices and per-phase shapes
remain in the raw reports. Templates and artifact identities were not replaced.

## Reproduction and limits

The executable SHA-256 is
`216adc9b7f0131c7143f1317a5500a5ed2d58c1bc748b6e3b93aa4c6e8dca8c5`,
with metallib
`4ffbbac48a99b495916c3fa0921ce813eb554de1a09aff408d9b5a5a8053e6b0`.
The archive is `native-types-probe1`; native source is commit
`02acd0e52d3dc88257dca5f3db4257aeda4db48e`. The retained runner verifies every
archived file before execution, applies a 600-second per-process bound and
stops its own process if a ranked benchmark job appears.

Each command selects `cache-off mtp-off contiguous --native-kv-probe-only`.
This mode constructs no serving backend, MTP assistant or SSD store. Its input
file supplies the exact model ID; no chat prompt or generated-token oracle is
measured. The `contiguous` argument is not a serving-backend result in this mode.
Recorded forward duration is diagnostic timing, not TTFT or decode throughput.
MLX active/cache-memory samples include loaded weights and allocator state;
they do not establish fleet capacity or a peak shared-admission bound.

These observations establish the native type and geometry table for subsequent
paged tests. Actual normal-MTP serving where applicable, complete paged SSD
restore, B1/B2/B4 comparisons, supported tool/vision requests, cross-slot physical
accounting and default promotion remain separate release gates. Production-key
SSD restart is not exercised by this cache-off probe.
