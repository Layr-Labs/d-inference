# Gemma 4 26B QAT 4-bit Continuous-Batching Baseline

This document freezes the pre-optimization baseline for Gemma 4 26B QAT
4-bit on Darkbloom's production `ContinuousBatchingV2` engine. It is the
comparison point for subsequent Gemma prefill, decode, scheduling, and
batch-composition changes.

The requested "Q80 4-bit" model was interpreted as the repository's QAT
4-bit build:

```text
mlx-community/gemma-4-26B-A4B-it-qat-4bit
```

The machine-readable companion is
[`2026-07-23-gemma-4-26b-qat4bit-continuous-batching-baseline.json`](2026-07-23-gemma-4-26b-qat4bit-continuous-batching-baseline.json).

## Environment

| Field | Value |
|---|---|
| Date | 2026-07-23 |
| Host | MacBook Pro, Apple M4 Max |
| CPU | 16 cores (12 performance, 4 efficiency) |
| GPU | 40 cores |
| Unified memory | 128 GB |
| Peak memory bandwidth used by report | 546 GB/s |
| macOS | 26.5.2 (25F84) |
| Provider version | 0.7.14 |
| Root commit | `0fb9d2b689e4934caf01c7242c1d2ea992ebeff5` |
| `libs/mlx` | `d5a240408508f2be37f1a4893da0b415e8c0db55` |
| `libs/mlx-swift` | `df1fdc5f7821a1fabe921fdefbc42ac74dcfb6bc` |
| `libs/mlx-swift-lm` | `dc2cd5510cadc7813044c4d0571feca83f39b60a` |
| Model snapshot | `0e3cbab38ce568cf6e23543010d08d03b731910c` |
| Measured weight payload | 15.608614044 GB |
| Quantization | 4 bit |
| `mlx.metallib` SHA-256 | `2e535253422c537dac8039ccae10305a7fece153341b8e96c3d52ad18bc58bfa` |
| Build | Swift release |
| Engine | Production `EngineV2Factory.makeProductionEngine` |
| Compiled decode | Enabled (default) |
| KV backend | Auto, therefore contiguous |
| Prefix cache | Disabled |
| MTP | Disabled (no drafter) |
| Maximum concurrent rows | 4 |
| Thermal state | No thermal or performance warning before or after the runs |

The arrival benchmark drives the production engine directly. It excludes
coordinator/network transport, provider bridge translation, tokenization,
prefix caching, MTP, provider memory-ledger reserves, and per-model TOML
overrides.

## Raw Prefill

Raw prefill is one full model forward over an exact-length token array. The
first shape can include residual compilation cost, so the baseline uses the
median of three same-process repetitions.

| Prompt tokens | Iteration | Elapsed (ms) | Prefill (tok/s) |
|---:|---:|---:|---:|
| 128 | 1 | 167.561 | 763.901 |
| 128 | 2 | 152.359 | 840.119 |
| 128 | 3 | 152.392 | 839.940 |
| 512 | 1 | 407.261 | 1,257.180 |
| 512 | 2 | 406.100 | 1,260.773 |
| 512 | 3 | 405.871 | 1,261.484 |
| 2,048 | 1 | 1,584.270 | 1,292.709 |
| 2,048 | 2 | 1,578.110 | 1,297.755 |
| 2,048 | 3 | 1,584.189 | 1,292.775 |

| Prompt tokens | Median elapsed (ms) | Median prefill (tok/s) |
|---:|---:|---:|
| 128 | 152.392 | 839.940 |
| 512 | 406.100 | 1,260.773 |
| 2,048 | 1,584.189 | 1,292.775 |

## Production TTFT

Production TTFT uses a fresh prefix-cache-free engine for each request and
measures submission through the first token. It therefore includes internal
512-token prefill chunking, per-engine compiled-decode startup, scheduling, and
the first decode step.

| Prompt tokens | Iteration | TTFT (ms) | TTFT / prefill token (ms) |
|---:|---:|---:|---:|
| 128 | 1 | 214.071 | 1.686 |
| 128 | 2 | 207.612 | 1.635 |
| 128 | 3 | 201.864 | 1.589 |
| 512 | 1 | 474.926 | 0.929 |
| 512 | 2 | 477.477 | 0.934 |
| 512 | 3 | 455.228 | 0.891 |
| 2,048 | 1 | 1,800.396 | 0.880 |
| 2,048 | 2 | 1,825.301 | 0.892 |
| 2,048 | 3 | 1,790.626 | 0.875 |

| Prompt tokens | Median TTFT (ms) |
|---:|---:|
| 128 | 207.612 |
| 512 | 474.926 |
| 2,048 | 1,800.396 |

## Decode Batch Curve

Each row has a 64-token prompt and produces 64 measured decode tokens after
the first emitted token. Aggregate throughput sums work across every row;
per-request throughput is aggregate divided by the batch size.

| Batch | Elapsed (ms) | Per-request (tok/s) | Aggregate (tok/s) |
|---:|---:|---:|---:|
| 1 | 593.769 | 107.786 | 107.786 |
| 2 | 799.167 | 80.083 | 160.167 |
| 3 | 998.478 | 64.098 | 192.293 |
| 4 | 1,248.393 | 51.266 | 205.064 |

The B=1 result was independently repeated with a shorter decode and measured
106.909 tok/s.

## Arrival Invariance

Each scenario submits the same four distinct 512-token prompts and requires
exactly 64 greedy output tokens per request. One production engine is warmed
through every topology and reused for all measurements. Request IDs are unique,
pattern order rotates across repetitions, and every row must finish with
`.length` and exactly 64 tokens.

Scheduled delays are relative to the scenario start. Actual submissions were
within roughly 5-36 ms of those targets because Swift tasks can wake between
GPU scheduling operations.

### Per-Repetition Results

`Decode-window TPS` is `sum(N-1)` divided by the interval from the earliest
first token to the latest last token. For staggered workloads it intentionally
includes later prefills and low-concurrency gaps. `End-to-end TPS` is all 256
output tokens divided by submission-to-final-completion makespan.

| Schedule (ms) | Iteration | Decode-window TPS | End-to-end TPS | Makespan (ms) |
|---|---:|---:|---:|---:|
| 0/0/0/0 | 1 | 196.640 | 87.356 | 2,930.534 |
| 0/0/0/0 | 2 | 193.171 | 80.346 | 3,186.229 |
| 0/0/0/0 | 3 | 188.967 | 78.008 | 3,281.715 |
| 0/25/50/75 | 1 | 98.011 | 85.895 | 2,980.373 |
| 0/25/50/75 | 2 | 97.706 | 85.443 | 2,996.165 |
| 0/25/50/75 | 3 | 91.389 | 78.848 | 3,246.757 |
| 0/100/200/300 | 1 | 98.945 | 86.664 | 2,953.933 |
| 0/100/200/300 | 2 | 96.805 | 84.539 | 3,028.202 |
| 0/100/200/300 | 3 | 92.791 | 80.388 | 3,184.560 |
| 0/250/500/750 | 1 | 96.856 | 84.949 | 3,013.557 |
| 0/250/500/750 | 2 | 95.731 | 83.439 | 3,068.126 |
| 0/250/500/750 | 3 | 91.100 | 78.966 | 3,241.919 |

### Arrival Summary

The TTFT and per-request decode columns below pool all four rows across all
three repetitions. Row-level medians follow because pooled medians hide the
early request's decode degradation.

| Schedule (ms) | Median TTFT (ms) | Median request decode (tok/s) | Median decode-window TPS | Median end-to-end TPS | Median makespan (ms) |
|---|---:|---:|---:|---:|---:|
| 0/0/0/0 | 1,881.617 | 48.300 | 193.171 | 80.346 | 3,186.229 |
| 0/25/50/75 | 1,674.039 | 49.445 | 97.706 | 85.443 | 2,996.165 |
| 0/100/200/300 | 1,518.517 | 49.511 | 96.805 | 84.539 | 3,028.202 |
| 0/250/500/750 | 838.760 | 39.147 | 95.731 | 83.439 | 3,068.126 |

### Per-Row Medians

| Schedule (ms) | Row | Median TTFT (ms) | Median decode (tok/s) |
|---|---:|---:|---:|
| 0/0/0/0 | 0 | 1,881.617 | 48.307 |
| 0/0/0/0 | 1 | 1,881.621 | 48.302 |
| 0/0/0/0 | 2 | 1,881.616 | 48.298 |
| 0/0/0/0 | 3 | 1,881.617 | 48.293 |
| 0/25/50/75 | 0 | 416.939 | 24.469 |
| 0/25/50/75 | 1 | 1,706.011 | 50.010 |
| 0/25/50/75 | 2 | 1,681.038 | 50.004 |
| 0/25/50/75 | 3 | 1,656.017 | 50.000 |
| 0/100/200/300 | 0 | 424.961 | 24.241 |
| 0/100/200/300 | 1 | 1,656.409 | 49.813 |
| 0/100/200/300 | 2 | 1,550.689 | 49.808 |
| 0/100/200/300 | 3 | 1,461.150 | 49.803 |
| 0/250/500/750 | 0 | 435.674 | 24.196 |
| 0/250/500/750 | 1 | 621.315 | 29.229 |
| 0/250/500/750 | 2 | 1,306.804 | 49.892 |
| 0/250/500/750 | 3 | 1,008.552 | 49.888 |

### Invariance Result

- Every row produced exactly 64 tokens and terminated with `.length`.
- Every row's full token sequence was identical across all repetitions.
- Every row's full token sequence matched the corresponding burst row.
- Output behavior is invariant to arrival topology for this greedy corpus.
- Latency and decode allocation are not invariant to arrival topology.

A burst places all four requests in the prefill queue before work begins. All
rows receive their first token together near 1.88 seconds and then decode near
48.3 tok/s each. With any tested stagger, row 0 obtains its first token near
0.42 seconds, but later prefills interrupt it and reduce its decode rate to
roughly 24 tok/s. Later rows decode near 49-50 tok/s after their prefills finish.

The staggered decode-window rate is about half the burst rate because its clock
starts at row 0's early token and includes all later prefill gaps. It must not be
read as a 50% loss in completed workload throughput: end-to-end output TPS and
makespan improve modestly in these four-request scenarios.

## One-Command Reproduction

From the repository root:

```bash
make benchmark-gemma-contbatch
```

The command rebuilds the release provider after source changes, installs the
metallib matching the current MLX commit, runs the full matrix, compares the
summary with the machine-readable baseline, and writes timestamped plus
`latest` Markdown/JSON reports under `tmp/benchmarks/`.

The metallib cache is namespaced by the nested MLX commit plus any tracked diff
and untracked files. Dirty kernel work therefore cannot silently reuse the clean
commit's metallib, and the runner does not trust an unrelated global cache.

Optional runner arguments can be passed through Make:

```bash
make benchmark-gemma-contbatch \
  GEMMA_BENCHMARK_ARGS="--label my-change --iterations 5"
```

Use `--skip-build` only when the release binary already contains the changes
being measured:

```bash
make benchmark-gemma-contbatch \
  GEMMA_BENCHMARK_ARGS="--skip-build --label repeat-2"
```

The benchmark results are hardware- and thermal-state-specific. Compare runs on
the same host, keep background GPU work stopped, and prefer multiple repetitions
for decisions smaller than the observed run-to-run spread.
