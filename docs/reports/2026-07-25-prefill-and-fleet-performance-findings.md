# Prefill and Fleet Performance — Findings, 2026-07-25

Working notes from the session that shipped provider **v0.7.15** (CBv2 prefill
stack) and then measured the production system to decide what to do next.

Everything here is either measured or read out of the source. Where a number is
inferred rather than observed, it says so. Several widely-assumed things turned
out to be wrong; those are called out explicitly, because re-deriving them is
expensive.

---

## 1. What shipped in v0.7.15

Merged: `d-inference` #573, #574, #576, #577, #578; `mlx-swift-lm` #84
(`b177c35`). Tagged `v0.7.15`, registered with the coordinator at 07:12 UTC.

| Change | Mechanism |
|---|---|
| Prompt-output narrowing | Prompt chunks no longer build `[B, L, 262144]` logits for positions the engine never reads. Intermediate chunks project nothing; the frontier projects one row. |
| Final-layer tail pruning + last-query | The last decoder layer keeps full attention and every K/V write but evaluates only the frontier row. |
| Rectangular packed prefill | Equal-length text chunks run as ONE layer-major `[B, L]` forward instead of B separate ones. |
| Mixed-step prefill quota | `DARKBLOOM_CBV2_MIXED_PREFILL_CAP`, opt-in, default OFF. |

**Kill switches** (no rebuild): `DARKBLOOM_GEMMA4_PREFILL_TAIL_ROWS=0`,
`DARKBLOOM_GEMMA4_PREFILL_LAST_QUERY=0`, `DARKBLOOM_CBV2_MIXED_PREFILL_CAP=<n>`.
Prompt-output narrowing and packed prefill have **no env gate** — backing those
out means reverting the submodule bump.

### Measured impact (production, not benchmark)

Regressing `TTFT = intercept + slope x prompt_tokens` on gemma-4 routes
separates fixed cost from per-token prefill cost and controls for prompt size:

| Version | n | Fixed cost | Per-token | Implied | r2 |
|---|---:|---:|---:|---:|---:|
| 0.7.15 | 881 | **1,626 ms** | **0.9075 ms/tok** | 1,102 tok/s | 0.815 |
| 0.7.14 | 12,513 | 2,120 ms | 0.9464 ms/tok | 1,057 tok/s | 0.800 |

Fixed cost **-23%**, per-token **-4.1%**. Worked through real prompt sizes:
128 tok **-22%**, 979 (p50) **-17%**, 10,000 (p90) **-8%**.

This corroborates the synthetic benchmark (-15/-20/-19%) on independent traffic.
Residual confound: 0.7.15 machines ran slightly lighter at measurement time, so
some of the intercept gain may be reduced co-tenancy rather than code.

---

## 2. Instrumentation traps — read this before querying

These cost real time this session. Every one of them produced a confident wrong
conclusion first.

| Field / table | Reality |
|---|---|
| `providers.id` | **Churns per registration.** 5,381 rows in 24h = 348 distinct machines; one serial had 685 rows. **Always dedupe by `serial_number`** (`distinct on (serial_number) ... order by serial_number, last_seen desc`). |
| `actual_ttft_ms` | `FirstContentAt - DispatchedAt` (`coordinator/api/route_outcome.go:428`). **Provider-side only** — already excludes coordinator overhead and queue wait. Do not "subtract queueing" from it. |
| `queue_ms`, `pending_ms`, `backlog_ms`, `this_req_ms`, `cost_ms`, `health_ms` | **Router scoring penalties, not milliseconds.** Summed into a routing decision (`registry/scheduler_test.go:67`). Values like 2,452,501 are scores. |
| `queue_wait_ms` | Real, but populated only for the ~10% of requests that actually queued. |
| `dispatch_to_first_chunk_ms` | Byte-identical to `dispatch_ms`; it is DispatchedAt -> first *byte* (role preamble), not first content. **Not a prefill metric.** |
| `cache_affinity_key` | **Dead.** A DB trigger `clear_legacy_cache_affinity_key` blanks it on every INSERT/UPDATE (`coordinator/store/postgres.go:100-119`). It is always non-NULL but always the same empty value. |
| `telemetry_events` | **Stale since 2026-05-28.** 148k rows, none newer. |
| `inference_routes` | Huge. **Always bound `created_at > now() - interval '...'`** or you get a full scan that hangs. |
| `providers.last_seen` | Mutated in place — historical liveness cannot be reconstructed from it. Use `provider_sessions` connect/disconnect intervals instead. |

**The DB in `coordinator/.env` is the PRODUCTION PRIMARY** (`pg_is_in_recovery()`
= false), not a replica. Read-only recipe, needed in every shell call because
env does not persist:

```bash
export DBURL=$(grep -E '^EIGENINFERENCE_DATABASE_URL=' coordinator/.env | cut -d= -f2- | tr -d '"')
export PGOPTIONS='-c default_transaction_read_only=on -c statement_timeout=30000'
psql "$DBURL" -qAc "SELECT ..."
```

`default_transaction_read_only=on` is a per-connection libqp startup option; it
makes the **server** reject writes and cannot leak into the coordinator's own
sessions.

**Repo trap:** the main checkout `/Users/gaj/Documents/Builds/d-inference` has a
**stale submodule** at `libs/mlx-swift-lm` = `dc2cd55`. Master expects
`b177c35`. Analyze engine code in a worktree synced to master, or you will
conclude that shipped features do not exist.

---

## 3. Production shape (2026-07-25, ~07:00-07:30 UTC)

- **348 machines** total (deduped by serial); ~150 serving at any moment.
- TTFT: **p50 3,042 ms, p90 12,439 ms, p99 42,097 ms**.
- Prompt tokens: **p50 979, p90 9,993, p95 16,919, p999 74,473, max 124,754**.
- Two models: `gpt-oss-20b` (~58-61% of traffic) and `gemma-4-26b-qat-4bit`.
- Fleet-wide 503 rate ~1.3%.
- Regression across all traffic: **TTFT = 1,663 ms + 0.9914 ms/prompt_token**,
  r2 = 0.80. 97% of the prompt-proportional term is provider-side prefill.

---

## 4. Finding: half the fleet is idle — fleet partitioning, not churn

**~50% of live machines serve nothing while gemma-4 requests queue 22.9%.**

Not upgrade churn. Using `provider_sessions` (not `last_seen`), the idle rate is
a standing condition: **52.9% today, 52.9% yesterday, 55.4% two days ago, 64.1%
a week ago.** v0.7.15 machines were *less* idle (40.9%) than 0.7.14 (50.6%).

### Root cause

`EIGENINFERENCE_DEDICATED_MODELS` defaults to `"gemma-4"`
(`registry/dedicated_models.go:10`). `providerExcludedByDedicatedRuleLocked`
(`:96`) says a gemma-4 request may only route to a box whose **entire advertised
catalog** is gemma-4. It is a catalog-composition exclusion, not a capacity test.

| Partition | Machines | Hardware-trusted, >=36 GB |
|---|---:|---:|
| A — gemma-only (eligible) | 67 | 46 |
| B — mixed, **blocked for gemma** | 94 | **71** |
| C — no gemma | 131 | 39 |

| Model | Routes/hr | % queued | avg candidates |
|---|---:|---:|---:|
| gemma-4-26b-qat-4bit | 15,327 | **22.9%** | **4.3** |
| gpt-oss-20b | 21,416 | **0.0%** | 41.7 |

42% of demand is confined to ~23% of the fleet, while the gpt-oss partition has
literally zero queueing. **71 hardware-trusted >=36 GB machines with gemma-4
already on disk are barred purely because gpt-oss is also installed.**

Dominant shed is `ttft_too_slow`, 1,798/hr, `could_have_served=true`, average
best TTFT **78 seconds**.

### Fixes, cheapest first

1. **No code change** — remove `gpt-oss-20b` from disk on some of the 94 mixed
   boxes; they become dedicated gemma boxes immediately. gpt-oss has 0% queueing
   and can absorb it.
2. **Make the rule demand-aware** — allow mixed boxes when the dedicated pool is
   shedding. The memory-isolation guarantee it exists to provide is *already*
   enforced independently by `freeMemoryAdmits` (`registry/scheduler.go:1301`)
   and the provider's `UnifiedMemoryCap`. The catalog exclusion is redundant.
3. **Demote to a routing cost penalty** so dedicated boxes win when available but
   mixed boxes serve rather than 429.

### Secondary idle causes

- **50 idle at `trust_level='self_signed'`** (96% idle). `registry/persistence.go:75`
  never restores trust above self-signed on reconnect, so a restart demotes a box
  until MDA re-attestation. ~35 self-promote; **~17 genuinely stuck**, 6 for >24h.
- **24 idle at <=24 GB** with a **0% success rate** (0/312 over 6h, 169 provider
  503s). `freeMemoryAdmits` over-admits that tier; `capacity_cooldown` only
  catches it after burning user-visible requests. **This is a real defect.**

---

## 5. Finding: prefix caching is OFF, and structurally cannot help gemma-4

Live `GET /v1/cache/status`: `routing_mode: "off"`, `ssd_lookups: 0`,
`ssd_hits: 0`, `ssd_donations: 0`. `exact_cache_plan_total{outcome="off"}`
= 938,241. **Zero lookups have ever been attempted.**

Set by `EIGENINFERENCE_CACHE_ROUTING_MODE=off` (`deploy/environments/prod.env:58`).
**This was a deliberate operator decision** after cache-hit problems in an
earlier enablement — not an oversight.

Even flipping it back would barely register, because four more gates multiply:

| Gate | Coverage |
|---|---|
| Sampling | 10% live (`prod.env` says 1%) |
| Protocol v2 providers | 34 of 255 = **13%** |
| Healthy cache models | 35 ready vs **105 `cache_init_failed`** = 25% |
| Donations that ever wrote a block | **0** (`no_complete_block: 1579`) |

~**0.3% effective coverage**, on a write path that has never persisted a block.
Dominant init failure is `promptContractID == nil`
(`EngineV2SlotFactory.swift:337-347`) with only 3 prompt contracts loaded.

### The structural blocker for gemma-4

`SSDPrefixCache.swift:783-788` sets `donationFloor = adoptionBoundTokens +
minEffectiveTokens`:

| Model | Floor | Requests that can ever donate |
|---|---:|---:|
| gpt-oss-20b | 2,560 | 38.4% |
| gemma-4-26b-qat-4bit | **26,624** | **2.3%** |

The 25,600-token `frozenFullReplay` bound (`PrefixCachePolicy.swift:151-154`)
exceeds typical gemma prompts by ~18x. **39% of traffic is excluded by policy,
permanently**, regardless of hit rate.

Ceiling with a *perfect* cache: gpt-oss p90 **-38%**; gemma-4 **~0%**; all
traffic p50 -12%, p90 -24%.

**Counters live only in coordinator RAM and reset on restart** — which is why
nobody had measured this. Persist them regardless of what else is decided.

---

## 6. Finding: head-of-line blocking is NOT the tail driver

Hypothesis was that 124k-token prompts block everything behind them. **The data
says giant prompts cause ~0% of the p90/p99 tail.** Blocking costs ~640 ms of
p50 (21%) and essentially nothing at the tail.

Counterfactual (remove all co-tenancy): p50 3,024 -> 2,385 (**-21%**);
p90 12,171 -> 12,287 (**0%**); p99 40,089 -> 40,242 (**0%**).

**Why:** `4 rows x 512 tokens = 2,048` = exactly `maxBatchedTokensPerStep`. Every
running prefill row gets its full 512-token chunk *every step*
(`SchedulerV2.swift:287`, `:374-377`). A 124k prompt occupies 244 steps but never
denies the other three rows their chunk. A giant neighbor is a **longer-lived**
blocker, not a harder one. Confirmed: victim TTFT scales with the *count* of
co-prefilling rows and is flat in their size.

The tail is **own prompt size**: above p99, 74.8% of routes are >20k prompts
(2.3% of traffic). A sub-2k prompt essentially never reaches global p90
(19 of 11,228).

**Therefore SJF / size-aware admission is low value** — its entire ceiling is the
639 ms of p50, and it adds starvation risk for the >20k class.

### What IS worth doing from that analysis

**Hardware-aware routing.** Prefill throughput spans **2.9x** across the fleet
for >=8k prompts (M1 Ultra ~440 -> M5 Pro ~1,260 tok/s), and **39.2% of
big-prompt traffic lands on sub-800 tok/s chips.** Routing big prompts to fast
hardware: **p90 -16%, p99 -34%.** `hardware_chip`/tier are already in the
registry and on every route row.

Also: coordinator overhead is 23 ms at p50 but **6,234 ms at p99** (15% of
end-to-end). Bug-shaped, worth separate investigation.

---

## 7. Roofline — Gemma 4 26B-A4B QAT 4-bit on M4 Max (40c, 128 GB)

Hardware verified: 546 GB/s memory bandwidth, ~16.2 TFLOPS FP32 FMA peak, **no
matrix accelerator**, NAX unavailable (needs GPU gen >=17; M4 is gen 16).

Model: 30 layers = 25 sliding (window 1024, head_dim 256, 8 kv heads) + 5 full
(head_dim 512, 2 kv heads, `attention_k_eq_v` so no `v_proj`). Dense MLP **and**
MoE run in *parallel* branches every layer. 128 experts, top-8, 4-bit.

### Per-token FLOP budget (prefill, P=512)

| Component | GFLOP/tok | Share |
|---|---:|---:|
| MoE experts | 2.8547 | **45.2%** |
| Attention projections | 2.2204 | 35.2% |
| Dense MLP | 1.0705 | 17.0% |
| Attention scores | 0.1471 | 2.3% |
| Router | 0.0216 | 0.3% |
| LM head (once per prompt) | 1.4764 | — |

### Prefill

Runs at **~9.6 TFLOPS useful against ~13 TFLOPS achievable = 74% efficiency**.
Floor is `6.32 GFLOP/tok / 13 TFLOPS` = 0.486 ms/tok ~ **2,060 tok/s**; we are at
~1,350-1,400. **Total headroom 1.47x; ~1.30x realistically reachable.**

Time split at P=512: MoE 41.8%, attn projections 21.5%, **fixed per-request
overhead 14.3% (~54-64 ms)**, dense MLP 10.4%, elementwise 6.1%, attn matmuls 4.1%.

### Decode

Bandwidth-bound: **2,444 MB read per token**, of which experts 32.8%, dense MLP
23.3%, attention weights 25.5%, LM head 17.0%, KV <1%.
Roof at 546 GB/s = 223 tok/s; measured B=1 is 106 tok/s = **259 GB/s effective,
47% of pin rate**.

Batch scaling is fully explained: **66% of decode bytes are batch-invariant**,
and expert draws are **91% distinct at B=4** (`E[unique] = 128(1-(1-8/128)^B)`).
Amdahl predicts 2.11x at B=4; measured 1.92x. **B=4 will never approach 4x.**

Only large decode lever is **MTP / speculative decoding** (infrastructure already
exists): 1.24-1.79x depending on depth and acceptance.

### CORRECTION: the "MoE runs at 3 TFLOPS" claim was wrong

Widely repeated, **arithmetically impossible**: at 3.0 TFLOPS the MoE stage alone
would take 487 ms, but the entire measured 512-token TTFT is 380 ms. Experts
actually run at **~9.2 TFLOPS useful** (two independent derivations agree within
7%). The whole remaining MoE win is ~1.11x, not 4x.

The gap is **tile padding**, exactly: `gather_qmm_rhs` hardcodes `bm=16,bn=32`
(`quantized.cpp:1279`), and the kernel runs one full `16xBNxK` matmul per
distinct expert inside each 16-row tile (`kernels/quantized.h:2334-2345`).

**Closed form: `inflation(R) = 1 + 16*E/R` where `R = tokens x topK`, `E = 128`
=> `inflation(C) = 1 + 256/C`.** Predicts 1.500 at C=512 (measured 1.465) and
1.125 at C=2048 (measured 1.116).

### CORRECTION: packing and chunk growth are the same thing to MoE

`Gemma4Experts.callAsFunction` (`Gemma4Text.swift:871-874`) flattens **B and S
together**. A `[4,512]` packed chunk and a `[1,2048]` chunk are the *same* call to
`SwitchGLU`. Both sort (`doSort = indices.size >= 64`) and both reach
`gather_qmm_rhs` (needs `B/E >= 4`, i.e. >=64 tokens). **Packing did not change
which kernel runs — it changed `R`.**

Consequence: packing captured the MoE win **only for concurrent bursts**. Most
production chunks run `B=1` and never got it. Raising `C` is the cheap way to
give single requests the same regime.

### THE major structural finding: we never use fused attention

```
sdpa_full_supported_head_dim   = {64, 80, 128}      <- prefill
sdpa_vector_supported_head_dim = {64, 96, 128, 256} <- decode
```
(`scaled_dot_product_attention.cpp:621-626`)

Gemma 4 uses head_dim **256** (sliding) and **512** (full). So **all 30 layers
fall back to the composed path in prefill**: `matmul -> mask -> softmax ->
matmul`, materializing a `[C, kL]` score tensor with **no causal block skipping**.

Not a bug and not a regression — MLX simply never implemented a `bd=256` full
kernel. **GPT-OSS uses head_dim 64 and is entirely unaffected.** Gemma decode is
mostly fine too: the 25 sliding layers hit the fused *vector* kernel; only the 5
full layers (512) fall back, and at `qL=1` their scores are trivial.

Sliding executed/useful ratio is `(1023+C)/1024`: **1.499x at C=512, 2.0x at
C=1024, 2.67x at C=2048.**

---

## 8. Memory: the score tensor, and why the reserve is the real limit

Score tensor is `[batch, heads, C, kL]` — a **transient activation, not KV**.

| Config | One full-attn layer @124k ctx |
|---|---:|
| C=512 (today) | **2.04 GB** |
| C=2048 | **8.18 GB** |
| Any C, 128-row sub-blocking | **0.51 GB** |

For comparison, the **entire KV cache at 124k is only 2.76 GB** — `attention_k_eq_v`
means full layers skip `v_proj`, they have 2 KV heads, and the sliding window caps
25 of 30 layers at 0.21 GB total.

**Why we would OOM despite having a memory model:** `UnifiedMemoryCap` reserves a
**flat constant** for activations —
`defaultActivationReserveBytes = 3 GiB`
(`provider-swift/Sources/ProviderCore/Inference/UnifiedMemoryCap.swift:45`). It
does not scale with chunk size, context length, or concurrency. 2.04 GB fits
inside it; 8.18 GB does not, and nothing in admission would notice. It is also a
**load-time** gate, not per-request, so it cannot react to a 124k prompt arriving.
On unified memory the failure mode is swap/pressure, not a clean rejection.

**Sub-blocking makes the score tensor O(1) in C, which keeps the flat reserve
true.** That is why it is a hard prerequisite for chunk growth — the alternative
is re-deriving the reserve as a function of `C x max_context x heads` and
threading it through the load gate, `GlobalKVCacheBudget`, and the coordinator's
`freeMemoryAdmits` mirror.

**KV quantization is the wrong tool** (KV is 2.76 GB, the problem is 8-24 GB of
activations; it also costs quality and disables prefix caching).
**Paged attention is the wrong tool** (it manages KV allocation, not score
materialization) — and worse, our paged backend reports
`supportsPackedPrefill = false`, so enabling it would **disable the packed
prefill we just shipped**.

---

## 9. Engine plan — sequence and expected gains

Speedup vs shipped v0.7.15, on total prefill wall clock:

| Configuration | P=979 (p50) | P=10,000 (p90) | Weighted |
|---|---:|---:|---:|
| Chunk 512->2048 **alone** | 1.04x | **0.95x (REGRESSION)** | — |
| Query sub-blocking **alone** | 1.03x | 1.05x | 1.046x |
| **Both together** | 1.12x | **1.17x** | **1.158x** |
| + kill fixed per-request cost | 1.24x | 1.18x | 1.173x |
| + adaptive expert tail bodies | 1.30x | 1.20x | 1.196x |
| + fused SDPA hd256 (everything) | 1.35x | 1.28x | 1.266x |

**Chunk growth alone regresses p90** because sliding executed KV goes as `W-1+C`.
Sub-blocking alone does not monetize the MoE side. They are worth 1.16x together
and little apart. **1.196x of the available 1.27x needs no `libs/mlx` changes.**

### Recommended sequence

1. **Profile the ~54-64 ms fixed cost** (1 day). `CBV2_STEP_PROFILE=1` +
   `CBv2StepProfiler.summaryTable()` already exist. Suspects: first-chunk Metal
   pipeline specialization for unwarmed `align_M/N/K` variants, host-side setup,
   first-token readback sync.
2. **Query sub-blocking, q=128** (2-3 days) in `AttentionV1.swift` —
   `updateAndAttendRow:209-227`, `borrowAndAttendRow:342-363`, generalizing
   `attendSerialQueries:386-408`. Do **both** sliding and full layers (full layers
   are the memory case). `maskMode` needs no change. Last-ulp numerics.
3. **Chunk growth** (2-3 days): `prefillChunkSize` 512 -> 2048,
   `mixedStepPrefillTokenCap = 512`, `maxBatchedTokensPerStep` 2048 -> 4096.
   Note `EngineV2Factory+Production.swift:415` ties the paged ring's
   `maxPrefillChunk` to the same field — lockstep by construction.
4. **Fixed-cost fix** from step 1.
5. **RE-MEASURE, then** adaptive expert tail bodies `BM 32/16/8` in `libs/mlx`.
   Value drops from 1.064x to a marginal ~1.02x once chunk growth lands.

**Do NOT port `tmp/patches/w3-r1-expert-qmm-nested-mlx.patch` as-is.** Its
descriptor kernel opens with `if (gid != 0) return;` — a single GPU thread
serially binary-searching 128 expert segments. Its only real benefit came from
the `<=16-row` tail body. It also changes `qmm_t_impl`'s `M` from
`const constant int&` to `const int`, which demotes the value out of constant
address space for **every** quantized kernel and costs ~1% decode.

**Do NOT do fused SDPA (hd 256) now:** marginal 1.06x for 2-4 weeks of Metal work
at the 32 KB threadgroup-memory boundary, and it does not touch the `head_dim 512`
full layers that dominate at p90.

### Chunk growth should not be uniform across the fleet

`prefillChunkSize` is a per-engine config (default 512, never overridden in
production — `EngineV2Factory+Production.swift:356`), and `EngineV2Config.swift`
has **zero hardware awareness**. The MoE benefit is machine-independent, but a
2048-token chunk takes ~1.6 s on an M5 Pro and **~4.7 s on an M1 Ultra**, and
co-running decode waits out the whole step. Better design: bound step *time*, not
step *tokens*, using the existing per-provider prefill EWMA
(`observed_prefill_tps` in `EngineV2Bridge`):
`chunk = clamp(target_step_ms x measured_tokens_per_ms, 512, 4096)`.

---

## 10. Priority list

| # | Lever | Value | Type |
|---|---|---|---|
| **1** | Unblock the gemma pool — 71 trusted >=36 GB machines barred by the dedicated-catalog rule | 22.9% queueing -> ~0; kills 78 s shed TTFTs | **Config** |
| **2** | Hardware-route big prompts — 2.9x fleet spread, 39% land on slow chips | p90 -16%, p99 -34% | Coordinator |
| **3** | Fix gemma's 26,624-token cache floor, then `cache_init_failed` + donations | unlocks 39% of traffic; gpt-oss p90 -38% | Engine + config |
| **4** | Engine: sub-blocking -> chunk growth -> fixed cost -> tail bodies | ~1.30x ceiling | Kernel/Swift |
| 5 | Coordinator p99 overhead (23 ms p50 vs 6,234 ms p99) | 15% of e2e at p99 | Bug-shaped |
| 6 | 24 GB boxes admitted for gpt-oss fail 100% (0/312) | correctness | Bug |
| 7 | MTP / speculative decoding | decode 1.24-1.79x | Engine |

**Items 1-3 are each worth more than the entire remaining engine ceiling, and two
of them are configuration rather than code.**

---

## 11. Open items

- **Verify live coordinator config** via IAP into `darkbloom-coordinator`
  (`us-east4-a`, `darkbloom-mainnet`) — confirm `EIGENINFERENCE_DEDICATED_MODELS`
  is actually set/unset, and diff live env against
  `deploy/environments/prod.env`. An investigation was dispatched but not
  completed.
- **Reconstruct the prefix-cache incident** from Datadog (`DD_API_KEY`,
  `DD_APP_KEY`, `DD_SITE` in `coordinator/.env`) — the owner disabled it after
  cache-hit problems; the specific failure was never identified this session.
- **`TestIntegrationMixedVersionReleasedV0712Provider` fails** with
  "SIP status: disabled" on the CI runner — appears environmental (the test
  refuses to skip silently), but was never confirmed, and it means the
  mixed-version compatibility gate did not actually run for v0.7.15.
- **Check `gpu_memory_peak_gb` vs prompt size** in `inference_routes` to see
  whether the 2 GB score tensor already causes pressure at C=512.
- **W3 expert-kernel patches** live at `tmp/patches/w3-r1-expert-qmm-*.patch`
  plus two `git stash` entries in `libs/mlx-swift` and its nested mlx. **`tmp/`
  is gitignored** — that work is not in version control and will be lost on a
  clean.
