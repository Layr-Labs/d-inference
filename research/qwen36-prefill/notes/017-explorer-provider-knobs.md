# 017 — Explorer: provider knobs for Qwen 3.6 TEXT prefill

Status: mapped (code read, not re-measured on Mac)

Scope: env knobs and factory defaults wired through the four assigned files, plus
downstream effects those files explicitly connect for Qwen 3.6 35B-A3B VL on CBv2.
Repo source is provider release **0.8.10** (`ProviderCore.version`). GOAL machine
runs the same installed build — knob inventory below matches that release unless noted.

---

## Factory defaults (no environment variables)

Backend prep in the EngineV2 factory serving extension builds one `CBv2SchedulerConfig`
instance used for both paged pool sizing and the live engine.

| Field | Default | Qwen TEXT prefill effect |
|---|---|---|
| `prefillChunkSize` | **512** | Plain chunk size when solo stripe does not arm. At 8K solo → 16 weight passes (vs 4 at stripe 2048). |
| `soloPrefillStripeTokens` | **2048** via `defaultSoloPrefillStripeTokens` | See env table — factory sets this unless env disarms. |
| `maxBatchedTokensPerStep` | **2048** | Per scheduler step token budget across batched prefill + decode. Can cap a stripe/chunk. |
| `maxConcurrentPartialPrefills` | **nil** (unlimited) | How many running rows may receive prompt chunks in one plan. nil = FCFS interleave (B=4 burst: all TTFTs ≈ makespan). |
| `maxConcurrentRequests` | caller param | Benchmarks: **1** (`SchedulerPrefill`), **4** (`ArrivalInvariance`), **B** (`ThroughputSweep` decode). |
| `maxWaiting` | **64** | Queue depth before capacity error; not on hot prefill path for isolated benches. |
| `enablePrefixCache` | **false** until SSD cache attached | Benchmarks pass `prefixCache: nil` → always **off**. |
| KV backend (`.auto`) | **contiguous** since v0.8.1 | Default serving + `--kv-backend auto`. Paged only via explicit selection. |
| `CBv2MTPConfig` | `enabled: false` default | Benchmarks do not pass `mtpDrafter` → **MTP inactive** on prefill/decode in harness. |
| `useLegacyRequestTimeout` | **false** (monotonic leases) | Affects request lifetime, not prefill kernel choice. |

Qwen model capabilities (from `MLXLLM.Qwen35.cbv2Capabilities`, consumed by factory):

- `supportsPackedPrefill` is true — engine *may* pack concurrent text prefills (B>1).
- `supportsMTP` is true — irrelevant when no drafter wired (benchmark default).
- Recurrent/GDN state spec from hybrid layer schedule (10 full + 30 GDN) — not env-tunable here.

---

## Live env knobs (change Qwen TEXT prefill)

### Wired in EngineV2 factory serving extension

| Knob | Default (0.8.10) | B=1 prefill | B=4 aggregate prefill | Rollback | In 0.8.10 |
|---|---|---|---|---|---|
| `DARKBLOOM_CBV2_SOLO_PREFILL_STRIPE` | unset → **2048** | **Arms** when exactly one live text row, no decode waiter (`SchedulerPrefill` path). 8K prompt → ~4 expert-tile passes vs 16×512. | **Disarmed** — multiple concurrent prefill rows fail solo gate → **512-token chunks** unless packed path merges rows. Set `0` or `≤512` to force plain chunks for A/B. | set to `0` or any value `≤512` disarms (drain-restore convention). | Yes |
| `DARKBLOOM_CBV2_MAX_PARTIAL_PREFILLS` | unset → **unlimited** | No effect on solo B=1. | Caps rows getting prompt work per step. value `1` serializes prefill (mean TTFT ↓, **same aggregate tok/s** — policy, not throughput). Nonpositive → unlimited (fail-open). | unset or remove | Yes |
| `DARKBLOOM_CBV2_PAGED_KV` | unset → paged **allowed** | With `.auto`/default: **no effect** (contiguous). Explicit `--kv-backend paged`: set to `0` **degrades** to contiguous (kill switch). | Same | `0` / `false` / `no` / `off` | Yes |
| `DARKBLOOM_CBV2_PAGED_KV_DTYPE` | unset → **float16** | Only if backend resolves **paged**. fp32 halves page count at same byte grant. | Same | N/A on contiguous default | Yes (paged arm only) |
| `DARKBLOOM_CBV2_LEGACY_REQUEST_TIMEOUT` | unset → **off** | Restores flat 120s wall (incident rollback). Does not change chunk/stripe/MoE path. | Same | `1` / `true` / `yes` / `on` | Yes |
| `DARKBLOOM_KV_BACKEND_GUARD` | unset | Path override for crash-loop guard record read by `KVBackendGuardStore`. Guard only affects `.auto`→paged (dormant while `.auto`→contiguous). | Same | Delete stale guard file / new release | Yes |

### CLI / config (reaches same factory; benchmarks)

| Knob | Default | B=1 | B=4 | Rollback | In 0.8.10 |
|---|---|---|---|---|---|
| `--kv-backend` / `engine_v2_kv_backend` | **auto** → contiguous | Contiguous KV; Qwen VLM slot veto also forces contiguous even if paged requested. | Same | `contiguous` explicit | Yes |
| `[gemma_optimizations]` → projected environment (see below) | both **on** | Expert-tile **trust** path for MoE gather (Qwen uses same `MLX_GATHER_QMM_EXPERT_SLICES` latch as Gemma). | Same per-row; packed/batch geometry differs | disable `weighted_r1` in `provider.toml` | Yes |

### Benchmark-only env

| Knob | File | Default | Effect on Qwen prefill |
|---|---|---|---|
| `DARKBLOOM_ARRIVAL_TOLERANCE_MS` | `ArrivalInvarianceBenchmark` | **5 ms** (⅕ of 25 ms min gap) | Scheduling QA only; does not change engine config. B=4 burst pattern. |
| `DARKBLOOM_ARRIVAL_TOLERANCE_MS` override | same | — | Loosen if host cannot hold 5 ms arrival error. |

### Downstream env (not declared in the four files; set by benchmark serve-prep or MLX init)

These **do** change Qwen MoE prefill on 0.8.10 but live outside the assigned files:

| Knob | Default | B=1 | B=4 | Rollback | In 0.8.10 |
|---|---|---|---|---|---|
| `MLX_GATHER_QMM_EXPERT_SLICES` | **`trust`** when `[gemma_optimizations].weighted_r1` is true (benchmark default) | E=256 expert-tile route + skip descriptor drain — **kept optimization** per note 002. | Same kernels; batch changes assignment layout | `0` off, or `1` restore drain; or disable `weighted_r1` in config | Yes |
| `MLX_GEMMA4_FUSED_WEIGHTED_UNSORT` | coupled to `weighted_r1` | Coupled expert path (name says Gemma; applies to shared gather QMM) | Same | config off | Yes |
| `DARKBLOOM_GEMMA4_PREFILL_CHUNK_EVAL` | **18** when `prefill_layer18` is true | **Gemma-only** (`Gemma4Text.swift`); **no Qwen effect** | — | set to `0` | Yes (inert for Qwen) |
| `DARKBLOOM_CBV2_ATTN_QUERY_BLOCK` | **128** (`AttentionV1.swift`) | Blocks full-attention prefill queries; reduces score tensor / dispatches on long chunks | Same per row | set to `0` disables blocking | Yes |
| `DARKBLOOM_ENGINE_V2_VLM_PARITY_CHECK` | **on** | Load-time tiny forward only (extraction gate); not in timed prefill | Same | `0` / `false` / `no` / `off` | Yes |
| `DARKBLOOM_PREFIX_CACHE` | **on** for serving | Benchmarks: cache **not constructed** → cold prefill always | Same | set to `0` (serving) | Yes (inert in benchmarks) |
| `DARKBLOOM_CBV2_MTP` | unset → **allowed** | Benchmarks: no drafter → **inert**. Serving: enables MTP **decode** when assistant loaded | Same | `0` / `off` | Yes |

---

## Retired / ignored (`EngineV2Config.swift`)

Parsed only for startup WARN; **no effect** on prefill:

`DARKBLOOM_ENGINE_V2`, `DARKBLOOM_ENGINE_V2_MODELS`, `DARKBLOOM_COMPILED_DECODE`,
`DARKBLOOM_GEMMA_B1_FAST_PATH`, `DARKBLOOM_B1_GREEDY_FAST_PATH`,
`DARKBLOOM_KV_GPTOSS_KERNEL`, `DARKBLOOM_ADAPTIVE_PREFILL_ALLOW_8192`,
`DARKBLOOM_KV_CAPTURE_MAX_INFLIGHT`, `DARKBLOOM_PREFIX_CACHE_MIN_PERSIST_TOKENS`.

v0.7.5+ is unconditionally CBv2; rollback is **release-level**, not per-box env.

---

## B=1 vs B=4 — what actually differs

```text
B=1 solo (SchedulerPrefillBenchmark):
  maxConcurrentRequests=1 → solo stripe CAN arm (2048 default)
  → fewer weight re-reads, expert tiles at 16k assignments/chunk

B=4 burst (concurrent equal-length prefills — GOAL metric):
  solo stripe OFF (multi-row running set)
  → plain 512 chunks UNLESS packed prefill merges cohort
  → capability flag true ≠ proof packed fires (see note 006)

Policy knob maxConcurrentPartialPrefills:
  changes TTFT spread, NOT aggregate tok/s (note 002)
```

**Harness gap:** `SchedulerPrefillBenchmark` is **B=1 only** (`maxConcurrentRequests: 1`).
`ArrivalInvarianceBenchmark` is B=4 but default **512** prompt + decodes 64 tokens (decode-heavy).
`ThroughputSweep` prefill leg uses **raw** `model.callAsFunction`, **not** CBv2 — do not use it
as the GOAL CBv2 prefill baseline.

For B=2/B=4 aggregate CBv2 prefill, executor needs a dedicated burst harness (or extended
sweep) with equal-length concurrent `submit()` and `maxConcurrentRequests ≥ B`.

---

## Model resolution: `--model qwen3.6-35b-a3b-vl-mtp-mxfp8`

Flow (`BenchmarkCommand` → `ModelScanner.resolveLocalPath`):

1. CLI `--model qwen3.6-35b-a3b-vl-mtp-mxfp8` (or config default) selects catalog id.
2. Scanner maps id → HF cache dir  
   `~/.cache/huggingface/hub/models--qwen3.6-35b-a3b-vl-mtp-mxfp8/snapshots/<hash>/`
3. `findLatestSnapshot` picks the snapshot subdirectory with **latest mtime**.
4. GOAL snapshot name **`local`** works if that directory exists and is newest under `snapshots/`.
5. Override for canary/tests: `DARKBLOOM_LIVE_MLX_QWEN36_MODEL_PATH`.

Load path in benchmarks:

- `readHasVisionConfig` → **VLM** → `VLMModelFactory.loadContainer` (full wrapper in memory).
- `EngineV2Factory.benchmarkServingModel` → `EngineV2VLMTextExtraction.extractTextModel`:
  - Builds **MLXLLM `Qwen35MoEModel`** sharing `language_model.*` weights only.
  - Forces `mtp_num_hidden_layers = 0` in decoded config → **inline MTP head off** on serving target.
  - Parity gate vs wrapper text path at load (optional skip via env).
- CBv2 engine runs on **extracted text tower**, not vision forward.

Registry id (R2/manifest): `EigenLabs/Qwen3.6-35B-A3B-MLX-VL-4bit-g64-router8-mtp` — different
string from local id; scanner keys off **local model id**, not registry name.

---

## Canary / benchmark contamination (vision? MTP?)

| Concern | Scheduler-prefill / arrival harness | Qwen36 canary live tests |
|---|---|---|
| **Vision compute in timed prefill** | **No** — text token prompts only; engine is extracted LLM skeleton. Vision weights may still **resident** in wrapper RAM. | **Yes** for VLM chat paths — loads image, exercises multimodal server stack. |
| **MTP in timed prefill** | **No** — `mtpDrafter: nil`, `CBv2MTPConfig.enabled` default false; extraction zeros inline MTP layers. | **Can be yes** — tests enable `DARKBLOOM_CBV2_MTP` and measure target vs MTP decode speedup. |
| **Prefix cache** | **Off** — `prefixCache: nil`. | Canary often sets `DARKBLOOM_PREFIX_CACHE=0`. |
| **KV backend** | `.auto` → contiguous (same as fleet default). | Serving slot factory path (contiguous default). |

**Verdict:** `darkbloom benchmark --scheduler-prefill --model qwen3.6-35b-a3b-vl-mtp-mxfp8` measures
**CBv2 TEXT prefill** on the extracted language model. It does **not** run vision tower or MTP draft
heads in the timed path. Residual risks: (1) full VLM wrapper memory footprint affects KV budget
derivation; (2) load-time parity forward; (3) confusing **ThroughputSweep** raw prefill with CBv2;
(4) canary tests mixing MTP/vision if someone cites canary numbers as prefill baseline.

---

## Quick rollback cheat sheet (0.8.10 prefill A/B)

| Goal | Action |
|---|---|
| Plain 512 chunks at all lengths | set `DARKBLOOM_CBV2_SOLO_PREFILL_STRIPE` to `0` |
| Legacy expert path (no trust) | disable `weighted_r1` in `provider.toml` + restart |
| Disable query blocking | set `DARKBLOOM_CBV2_ATTN_QUERY_BLOCK` to `0` |
| Force contiguous KV | default; or `--kv-backend contiguous` |
| Try paged KV (measurement) | `--kv-backend paged` (explicit; fails loud if unservable) |
| Disable SSD prefix (serving) | set `DARKBLOOM_PREFIX_CACHE` to `0` |

---

## Files read

- `provider-swift/.../EngineV2Factory` serving extension swift source
- `provider-swift/.../EngineV2Config.swift`
- `provider-swift/.../SchedulerPrefillBenchmark.swift`
- `provider-swift/.../ArrivalInvarianceBenchmark.swift`
- `provider-swift/.../EngineV2Factory+Benchmark.swift`
- `provider-swift/.../EngineV2VLMTextExtraction.swift`
- `provider-swift/.../EngineV2KVBackendPolicy.swift`
- `provider-swift/.../GemmaOptimizationEnvironment.swift`
- `libs/mlx-swift-lm/.../CBv2Contracts.swift` (scheduler defaults)
- `libs/mlx-swift-lm/.../Qwen35.swift` (capabilities)
- `libs/mlx-swift-lm/.../AttentionV1.swift` (query block)

Cross-refs: notes 002 (prior art), 006 (packed prefill surface).
