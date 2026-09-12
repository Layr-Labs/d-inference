# Gemma 4 26B Prefill, Decode, and Metal Profile — 2026-08-20

> Last updated: 2026-08-20 · commit `5d400cf75`

## Executive result

The accepted non-64K profile is complete for the production Gemma 4 26B QAT4 target on the local M4 Max:

- untraced prefill timing at 8K, 16K, and 32K, three repetitions each;
- untraced decode timing at context 512, 8K, and 32K for B=1/2/4, three repetitions each;
- complete structured traces for all 12 cells;
- early/middle/final deep detail for 44 actual chunks or engine steps;
- a 36.37 GB replayable capture of the 32K final prefill chunk;
- a 56.48 GB replayable capture of the 32K B=2 steady decode step;
- bracketed controls for expert descriptor readback, layer-18 submission, weighted unsort, final-tail narrowing, last-query attention, and compiled decode;
- real timing with the local Gemma assistant artifact across all nine decode cells.

64K is explicitly deferred and excluded at operator request. No 64K value is used below.

### Main conclusions

1. **Five full-attention layers dominate long-context prefill growth.** At the 32K final chunk they account for 8.339 GB of 10.225 GB logical score bytes (81.56%). The other 25 attention layers are already bounded by their 1,024-token sliding window.
2. **Final-tail and last-query specializations are large, real wins.** At 32K, disabling tail narrowing costs 7.60% TTFT; disabling only last-query final attention costs 6.61%. These effects are not additive because tail-off makes last-query ineligible.
3. **Decode batching does not approach linear scaling.** At 32K, B=4 reaches only 93.84 aggregate tok/s versus 67.46 at B=1; stored paired scaling efficiency is 34.59%, while per-request throughput falls from 67.46 to 23.46 tok/s.
4. **Long-context B>=2 decode has a command/primitive explosion inside MoE-combine-attributed work.** At steady 32K, dispatches rise from 1,885 at B=1 to 10,863 at B=2 and 11,407 at B=4. Logical layer and MoE scope counts remain fixed.
5. **Decode remains on vector/QMV routes through B=4.** Every steady step has 236 dense quantized descriptors and 90 expert GatherQMM descriptors; no matrix-route transition occurs.
6. **Expert descriptor trust is measurable.** Safe readback costs 4.36% prefill throughput at 8K and 2.68% at 32K versus explicit trust. Use trust only under the existing sorted-route qualification and correctness gates.
7. **The real Gemma MTP assistant is productive for B=1, mixed for batching, and currently harmful at long-context B>=2.** Workload acceptance was 100% in the nine timing cells, but 32K B=4 fell to 26.19 tok/s. MTP structured/GPU trace collection was paused before completion and is not claimed here.

---

## Evidence policy

- **Timing truth:** untraced release baseline and untraced bracketed controls only.
- **Operator truth:** structured diagnostic events, source geometry, and selected replayable captures.
- **Not timing truth:** diagnostic wall time, trace GPU interval unions, host gaps, graph-build durations, readback durations, or capture duration.
- **Unavailable:** private occupancy, ALU utilization, cache-hit rate, stall reasons, and per-kernel hardware counters. None is fabricated.
- **Sensitive:** `.gputrace` bundles may contain token IDs, activations, and replayable device buffers. They remain owner-only and must not be redistributed.

## Exact target and build

| Item | Value |
|---|---|
| Target model | `mlx-community/gemma-4-26B-A4B-it-qat-4bit` |
| Target snapshot | `0e3cbab38ce568cf6e23543010d08d03b731910c` |
| Target config SHA-256 | `29910322dd085f45c8f95c6c0f1611b20f722d6f6c8394321b34817e98a972fa` |
| Release binary SHA-256 | `b248d885007bd4d656d2ec8a541e442e20e99ab4c60797d6dedf5e9ef205a5de` |
| Metallib SHA-256 | `843685d0d04a10e9da7c124b342be91f4e4548a7a14bb13d35138b2009eedefa` |
| KV backend | contiguous |
| MTP in ordinary baseline | off |
| Prefix cache in scheduler prefill | absent |
| Baseline expert descriptor posture | safe readback (`MLX_GATHER_QMM_EXPERT_SLICES=1`) |

Target topology:

- 30 layers;
- 25 sliding-attention layers, window 1,024;
- full-attention layers 5, 11, 17, 23, and 29;
- Hq=16;
- sliding Hkv=8, D=256;
- full Hkv=2, D=512;
- hidden size 2,816;
- 128 experts, top-8 routing;
- expert intermediate size 704;
- affine W4/group-size-64 routed weights;
- 262,144-position target context limit.

Verification before profiling:

- `DiagnosticTraceTests`: 38 executed, 0 failures;
- `DiagnosticTraceGemmaDecodeTests`: 5 executed, 0 failures;
- clean provider release build passed;
- source-matched metallib staged;
- exact Gemma prefill and B=2 decode smokes produced complete, zero-drop traces;
- final source/security reviews found no P1/P2.

---

## Untraced prefill timing

Each row is three measured iterations after the mandatory warmup.

| Prompt | TTFT p50 | TTFT range | Prefill p50 | ms/token p50 | TPS CV |
|---:|---:|---:|---:|---:|---:|
| 8,192 | 5,587.98 ms | 5,457.27–5,703.54 | 1,465.82 tok/s | 0.6822 | 1.80% |
| 16,384 | 12,485.54 ms | 12,276.13–12,723.90 | 1,312.16 tok/s | 0.7621 | 1.46% |
| 32,768 | 28,979.46 ms | 28,548.15–30,819.32 | 1,130.70 tok/s | 0.8844 | 3.28% |

Scaling:

- 8K→16K: 2× tokens, 2.234× p50 TTFT, ms/token +11.71%.
- 8K→32K: 4× tokens, 5.186× p50 TTFT, ms/token +29.64%.
- Prefill throughput falls 22.86% from 8K to 32K.

This superlinear cost matches the five full-attention layers whose K grows with the complete prefix.

---

## Untraced decode timing

Each cell generates 128 tokens/request and has three repetitions.

| Context | Batch | Per-request p50 | Aggregate p50 | 128-token latency p50 | Ideal scaling efficiency |
|---:|---:|---:|---:|---:|---:|
| 512 | 1 | 105.31 tok/s | 105.31 tok/s | 1,215.50 ms | 100.00% |
| 512 | 2 | 79.06 tok/s | 158.12 tok/s | 1,619.02 ms | 76.54% |
| 512 | 4 | 52.47 tok/s | 209.87 tok/s | 2,439.58 ms | 49.24% |
| 8,192 | 1 | 88.62 tok/s | 88.62 tok/s | 1,444.42 ms | 100.00% |
| 8,192 | 2 | 61.90 tok/s | 123.80 tok/s | 2,067.83 ms | 70.18% |
| 8,192 | 4 | 35.80 tok/s | 143.20 tok/s | 3,575.53 ms | 40.40% |
| 32,768 | 1 | 67.46 tok/s | 67.46 tok/s | 1,897.53 ms | 100.00% |
| 32,768 | 2 | 42.46 tok/s | 84.91 tok/s | 3,014.94 ms | 63.74% |
| 32,768 | 4 | 23.46 tok/s | 93.84 tok/s | 5,455.83 ms | 34.59% |

Important variation:

- 32K B=2 aggregate CV: 8.50%.
- 32K B=4 aggregate CV: 12.40%.
- Long-context B>=2 comparisons therefore have materially more noise than short/B=1 cells.

Context degradation using p50 aggregate TPS:

- B=1, 512→32K: 105.31→67.46, −35.94%.
- B=2, 512→32K: 158.12→84.91, −46.30%.
- B=4, 512→32K: 209.87→93.84, −55.29%.

Batch tradeoff:

- B=4 increases aggregate throughput over B=1, but never approaches 4×.
- At 32K, per-request throughput drops 65.22% from B=1 to B=4.
- The trace shows why: long-context B>=2 creates much more command and primitive work per generated row instead of amortizing a fixed step efficiently.

---

## Prefill operator profile

### Exact attention geometry

Every measured prefill chunk has 2,048 tokens. Layers 0–28 use Q=2,048. Final full-attention layer 29 commits K/V for the whole chunk but executes Q=1 and emits one tail row.

Sliding attention reaches K=1,024 during the first chunk and then stays bounded. Full-attention K follows prefix position.

| 32K selected chunk | Full K | Sliding logical score bytes | Full logical score bytes | Total logical score bytes | Full share |
|---:|---:|---:|---:|---:|---:|
| 0 | 2,048 | 1.415 GB | 0.285 GB | 1.700 GB | 16.78% |
| 7 | 16,384 | 1.886 GB | 4.044 GB | 5.930 GB | 68.20% |
| 15 | 32,768 | 1.886 GB | 8.339 GB | 10.225 GB | 81.56% |

From first to final 32K chunk:

- full-attention logical score bytes: 29.23×;
- total logical score bytes: 6.01×;
- saturated sliding bytes: constant after the first chunk.

At the final chunk, ordinary full layers 5/11/17/23 each account for 2,084,569,088 logical score bytes. Last-query layer 29 accounts for 1,048,576. Relative to an ordinary full layer, the specialization avoids 99.95% of layer-29 logical score storage.

### LM-head pruning

The final projection is exactly:

```text
M=1, N=262144, K=2816, W4/group64
```

Earlier measured chunks have no LM-head scope. Shape-derived BF16 output falls from a hypothetical 1,073,741,824 bytes at M=2,048 to 524,288 bytes at M=1: a 99.95% reduction. This is shape-derived logical output, not measured DRAM traffic.

### MoE and QMM per 2,048-token measured chunk

- 30 MoE descriptors;
- 128 experts, top-8;
- 475,144 assignments: 29×2,048×8 plus 1×1×8 after final tail narrowing;
- 235 dense QMM descriptors on nonfinal chunks, 236 on the final chunk;
- 90 gather-QMM descriptors;
- 229 split-K edges;
- 29 expert-tile descriptors;
- zero expert-tile fallbacks;
- zero sortedness violations;
- weighted unsort requested in 30 layers, effective in 29 execution descriptors;
- one layer-18 async submission.

The final layer avoids 16,376 routed assignments because it operates on one row.

Expert histograms were not recorded. Assignment imbalance and hot-expert occupancy cannot be inferred from total assignment count.

### Prefill synchronization and memory

The safe-readback trace records 29 paired `expert_descriptor_readback` synchronizations per measured chunk. Independent untraced controls—not diagnostic wait duration—show the cost.

32K selected allocator summaries:

| Chunk | Peak max | Cache max | Active max |
|---:|---:|---:|---:|
| 0 | 18.38 GB | 4.51 GB | 18.27 GB |
| 7 | 19.39 GB | 16.62 GB | 18.42 GB |
| 15 | 19.53 GB | 19.51 GB | 19.53 GB |

Cache growth closely tracks prefix progression, but these allocator fields do not prove memory traffic or residency and must not be added together.

---

## Decode operator profile

### Invariant per-step logical topology

Every steady batched step has:

- 30 layers;
- 25 sliding and five full attention descriptors;
- 30 MoE descriptors;
- 240 routed assignments per generated token;
- 236 dense quantized descriptors per batched step;
- 90 gather-QMM descriptors per batched step;
- five SDPA fallbacks and ten QK/AV Matmul primitives per token.

Sliding geometry:

```text
Q=1, Hq=16, Hkv=8, D=256, K=min(current K,1024)
```

Full geometry:

```text
Q=1, Hq=16, Hkv=2, D=512, K=current prefix
```

### Context-growing score storage

Per generated token, five full layers materialize:

$$5\times16\times K\times2\ \text{bytes}$$

| Late context | K | Full-attention logical score bytes/token | Relative to 512 |
|---:|---:|---:|---:|
| 512 | 640 | 102,400 | 1× |
| 8K | 8,320 | 1,331,200 | 13× |
| 32K | 32,896 | 5,263,360 | 51.4× |

### Quantized routing

All B=1/2/4 cells stay on the vector/QMV route:

- dense M=B with vector limits 10/12;
- gather M=1, assignments=8B, vector limit 12;
- no matrix-route or split-K decode transition.

B=4 therefore does not gain a more efficient matrix kernel despite four active rows.

Weighted expert unsort is not active in steady decode: requested=0/effective=0. The prefill weighted-unsort win must not be transferred to decode.

### Long-context B>=2 expansion

Steady selected-step counts:

| Context/batch | Dispatches/step | Dispatches/token | CB creates/step | Cache max |
|---|---:|---:|---:|---:|
| 512 B1 | 1,760 | 1,760.0 | 124 | 0.73 GB |
| 512 B2 | 1,925 | 962.5 | 126 | 1.19 GB |
| 512 B4 | 2,195 | 548.8 | — | — |
| 8K B1 | 1,885 | 1,885.0 | — | — |
| 8K B2 | 4,347 | 2,173.5 | — | — |
| 8K B4 | 4,867 | 1,216.8 | — | — |
| 32K B1 | 1,885 | 1,885.0 | 134 | 20.42 GB |
| 32K B2 | 10,863 | 5,431.5 | 3,844 | 39.13 GB |
| 32K B4 | 11,407 | 2,851.8 | 5,088 | 75.10 GB |

The event expansion is inside fixed logical scopes:

- MoE-combine-attributed primitive begins: 450 at B=1, 2,610 at 8K B>=2, 9,090 at 32K B>=2.
- Dense-down-attributed begins: 180→900→3,060.
- Six dominant pipeline families explain 96.24% of the 32K B2-vs-B1 dispatch increment.

The exact pipeline-family excess matches the MoE-combine-attributed primitive excess. This strongly localizes the issue, but the reducer lacks a direct pipeline→logical-operation join, so that equality remains an inference rather than a proven one-to-one mapping.

### Decode bottleneck ranking

1. Long-context B>=2 MoE-combine/command topology expansion.
2. Vector/QMV quantized projection and gather routes through B=4.
3. Five context-growing full-attention layers.
4. Command-buffer and allocator/cache pressure.
5. Host gaps and descriptor readbacks are visible diagnostically but are not independently ranked as production latency.

---

## Optimization controls

Controls are bracketed by fresh default runs. Prefill controls have two measurements/cell; decode controls have one. Small deltas should not be called statistically significant.

### Prefill

| Disabled/changed behavior | 8K throughput delta | 32K throughput delta | 8K TTFT delta | 32K TTFT delta |
|---|---:|---:|---:|---:|
| Safe descriptor readback vs trust | −4.36% | −2.68% | +4.56% | +2.74% |
| Layer-18 async submission off | −1.31% | −1.07% | +1.32% | +1.05% |
| Coupled weighted-unsort + safe-R1 off | −2.91% | −1.48% | +3.00% | +1.52% |
| Final-tail narrowing off | −4.60% | −7.05% | +4.83% | +7.60% |
| Last-query final attention off | −2.33% | −6.22% | +2.39% | +6.61% |

Tail-off also disables last-query eligibility; those two rows are not additive.

### Decode compiled path

Disabling `MLX_COMPILED_DECODE` changes aggregate TPS by:

| Cell | Aggregate TPS delta | Elapsed delta |
|---|---:|---:|
| 512 B1 | −3.72% | +3.86% |
| 512 B4 | −1.03% | +1.04% |
| 32K B1 | −3.59% | +3.72% |
| 32K B4 | −0.38% | +0.38% |

Compiled decode is valuable at B=1; its measured benefit is marginal at B=4 under this workload.

---

## Real Gemma MTP timing — timing only

The local assistant was found after the initial cache search missed sibling repositories:

| Item | Value |
|---|---|
| Assistant | `mlx-community/gemma-4-26B-A4B-it-qat-assistant-4bit` |
| Snapshot | `bb94eae1b70a80dac16cbf959bb4b7d56bd1fb8c` |
| Architecture | `Gemma4AssistantForCausalLM` |
| Layers | 4 |
| Hidden size | 1,024 |
| Target-backbone hidden size | 2,816 |
| Quantization | affine W4/group64 |
| Weight SHA-256 | `3c4d43863abbbf455ec537c726eff7abeb88bb361e3ab23ff0d2d6006f620f74` |

The production artifact funnel rejected direct Hugging Face snapshot symlinks and extraneous files. Profiling used an owner-only materialized view containing byte-identical resolved `config.json` and `model.safetensors`.

The smoke produced nine rounds, nine proposals, five accepted tokens, 55.56% acceptance, exact 16-token output, and six target-forward savings. Every full timing cell was active, productive, exact, and fallback-free.

### MTP-on versus immutable MTP-off baseline

MTP-on has one measurement/cell; MTP-off baseline has three. These deltas are directional, not statistical.

| Context | Batch | MTP-on aggregate decode TPS | MTP-off p50 | Delta | Acceptance | Target forwards saved |
|---:|---:|---:|---:|---:|---:|---:|
| 512 | 1 | 126.60 | 105.31 | +20.22% | 100% | 64 |
| 512 | 2 | 168.26 | 158.12 | +6.41% | 100% | 128 |
| 512 | 4 | 162.04 | 209.87 | −22.79% | 100% | 254 |
| 8K | 1 | 104.92 | 88.62 | +18.40% | 100% | 64 |
| 8K | 2 | 73.40 | 123.80 | −40.71% | 100% | 127 |
| 8K | 4 | 110.17 | 143.20 | −23.06% | 100% | 254 |
| 32K | 1 | 71.34 | 67.46 | +5.75% | 100% | 64 |
| 32K | 2 | 47.12 | 84.91 | −44.51% | 100% | 127 |
| 32K | 4 | 26.19 | 93.84 | −72.10% | 100% | 253 |

Fresh same-harness MTP-off brackets exist for four cells:

- 512 B1: MTP +31.78%;
- 512 B4: MTP +12.53%;
- 32K B1: MTP +6.98%;
- 32K B4: MTP −41.95%.

The immutable and fresh B4 references differ materially, so the bracketed rows are more appropriate for those four cells. Both comparisons agree that 32K B4 regresses strongly.

Interpretation:

- This workload's 100% full-run acceptance is not representative of arbitrary prompts; the 16-token smoke accepted only 55.56%.
- MTP approximately halves target-forward count, but assistant execution and current batched scheduling overhead outweigh the savings at long-context B>=2.
- Do not enable this drafter fleet-wide. The evidence supports an experimental B=1 gate, followed by varied-prompt acceptance evaluation.
- MTP structured and replayable GPU traces are **not complete**. The local server could not invoke `DiagnosticTrace.finish()` before termination; both MTP agents were paused at user request while a benchmark-owned lifecycle path was being prepared. Empty attempts remain non-canonical.

---

## GPU captures

### 32K final prefill

- selected actual chunk index: 15;
- bundle regular bytes: 36,372,057,384;
- capture begin/end: valid;
- request/chunk/layer/op/primitive/pipeline/dispatch/encoder/command-buffer/public-GPU chain: valid;
- permissions: 0700 directories, 0600 regular files;
- contained relative symlinks: validated.

### 32K B=2 steady decode

- selected engine step: 79;
- generated ordinal: 64;
- bundle regular bytes: 56,477,581,698;
- complete attributable chain and permissions: valid.

The capture bundles are sensitive internal evidence. Do not attach them to issues, PRs, or public reports.

---

## Prioritized engineering actions

### P0 — Fix long-context B>=2 decode topology

Investigate why fixed MoE-combine logical scopes expand from 450 to 9,090 attributed primitive begins and why six pipeline families add 8,640 dispatches at 32K B=2. Required follow-up trace output: a direct pipeline→logical-op join and per-family shapes.

Success criterion: 32K B=2/B4 dispatches per token approach or beat B=1 instead of 2.88×/1.51× B=1.

### P0 — Qualify a batch-aware quantized route

B=4 remains below the current vector limits and never transitions from QMV. Benchmark a dedicated B=2/4 dense and gather route with exact W4/g64 shapes, including E=128/top-8 assignments. Do not globally lower thresholds without per-shape parity and end-to-end tests.

### P1 — Keep final-tail and last-query enabled

They are the largest measured prefill controls at 32K. Preserve full KV commit and one-row output semantics. Any refactor must prove final-token/logit and cache parity.

### P1 — Keep or qualify expert trust

Trust removes a 2.68–4.36% prefill penalty. Retain safe readback as the escape hatch; enable trust only for the verified sorted descriptor route and matching kernel/build.

### P1 — Improve five D512 full-attention layers

At final 32K they own 81.56% of logical score bytes. Focus on D512 QK/AV composition, q-blocking, score-buffer reuse, and final-layer last-query preservation—not the already bounded 25 sliding layers.

### P1 — Gate MTP by batch/context

Current evidence supports further B=1 evaluation, not general enablement. Before production:

- varied prompt corpus;
- repeated paired MTP-off/on timing;
- acceptance distributions, not one average;
- full MTP structured trace;
- one scoped target+assistant capture;
- B>=2 scheduler/round-overhead repair.

### P2 — Retain smaller wins

- layer-18 async submission: ~1.1–1.3%;
- coupled weighted-unsort/safe-R1: ~1.5–2.9%;
- compiled decode: ~3.6–3.9% at B=1.

---

## Validation and privacy

Final non-MTP audit verdict: **SHIP**.

- Baseline: 12 accepted cells, 36 measured samples, all arithmetic rechecked.
- Detailed: 12 valid cells, 44 selected-region records, 8,665 manifest entries after metadata repair.
- Controls: 33 canonical cells, all deltas reproduced.
- Baseline manifest: 119 entries rehashed.
- Detailed manifest: 6,245 regular entries plus 2,420 contained symlinks rechecked.
- Controls manifest: 210 root entries plus 198 per-cell entries rechecked.
- All canonical trace components: complete, zero drops, zero explicit failures, zero scope/open counts, no primitive-context exhaustion.
- Hardware metadata was reduced to an allowlist; serials, UUID/UDID, display identifiers, hostname, and user identity were removed without changing numeric measurements.
- Credential scan found no credential-like values in the audited small text artifacts.

---

## Artifact roots

Use `$HOME` in shared references; the roots contain local absolute paths internally.

```text
$HOME/Library/Caches/darkbloom/traces/gemma4-26b-profile-20260820/current-source/
├── baseline-20260820T214946Z-b248d885/
├── detailed-20260820T233226Z-b248d885/
├── controls-20260821T005707Z-b248d885/
└── mtp-20260820T-profile-b248d885/        # timing valid; traces incomplete/paused
```

Canonical files:

```text
baseline.../derived-statistics.json
baseline.../validation-final.json
baseline.../artifact-manifest.json
detailed.../matrix.json
detailed.../operator-breakdown.json
detailed.../selected-regions.json
detailed.../capture-results.json
detailed.../validation.json
detailed.../artifact-manifest.json
controls.../controls.json
controls.../deltas.json
controls.../validation.json
controls.../artifact-checksums.json
mtp.../timing.json
mtp.../mtp-metrics.json
mtp.../timing-validation.json
```

## Limitations

- 64K intentionally deferred.
- Baseline has only three repetitions; controls have two prefill and one decode measurement per cell.
- 32K B>=2 baseline variance is high.
- Diagnostic timing is not latency evidence.
- Composite long-context cells combine one complete all-run summary with isolated exact selected chains; they are not one selected run and must not be summed as multiple full executions.
- Expert histograms are absent.
- No private Metal performance counters were recorded.
- MTP timing is one run/cell and workload-specific; MTP structured/capture evidence is incomplete because collection was paused.
- Exact replay requires the local source worktrees, target/assistant snapshots, binary, and metallib identified by the recorded hashes.
