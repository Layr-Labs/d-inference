# Routing Telemetry & Algorithm Calibration

**Status:** Plan / design (branch `feat/inference-routing-telemetry`)
**Scope:** Coordinator only. No provider-swift or console-ui changes required for data collection. No prompt/response content is ever stored.

## 1. Why we are doing this

The router's scheduler (`coordinator/registry/scheduler.go`) is a **hand-tuned cost
model**. Every weight in it was calibrated *once*, on *one machine*
(M4 Max) against **Qwen2.5-7B-4bit — a model we do not even serve** (see the
`scheduler.go:42,57` comments) — and then frozen as a constant. Our actual fleet
serves **`gpt-oss-20b`** (min_ram_gb 24) and **`gemma-4-26b`** (alias →
`mlx-community/gemma-4-26B-A4B-it-qat-4bit`, min_ram_gb 36) — a 20B and a 26B,
both far larger than the 7B the constants were tuned on. Examples straight from
the code:

- `queueDepthPenaltyMs = 3000`, `totalPendingPenaltyMs = 750`
- `effectiveTPSLoadFactor = 0.27` (per-request TPS decay under batch)
- `kvCacheBytesPerToken = 400000` (KV footprint for the admission gate)
- health penalties: `memoryPressure×4000 + cpuUsage×1500 + gpuUtil×5000 + thermal(fair 2000 / serious 8000)`
- cold-load penalty `slotStatePenaltyUnknown = 30000`, `idle_shutdown = 20000`
- decode-TPS fallback chain `observed EWMA → fleet median → sqrt(memBandwidth)`
- prefill-TPS fallback `decodeTPS × 4.0`

These numbers decide which machine every request lands on, yet **we have no
measured feedback telling us whether they are right** for `gpt-oss-20b` or
`gemma-4-26b` on the hardware tiers we actually run (M-series Macs of varying
chip/memory), or for a thermally-throttled laptop. The constants were tuned on a
7B model on one M4 Max; we serve a 20B and a 26B across a heterogeneous fleet. We
are flying blind. **The concrete calibration grid is therefore small and
tractable: 2 models × the handful of chip/memory tiers in the fleet.**

The goal of this work is to **record every input the scheduler saw, the decision
it made, and what actually happened**, so we can:

1. **Explain any single routing decision** — "why did request X go to machine Y,
   what were Y's numbers, and what were the runners-up?"
2. **Calibrate the cost model from real data** — replace frozen global constants
   with measured, per-(hardware-tier, model) values.
3. **Detect mismatches** — where the model's prediction diverged from reality
   (predicted-fast-but-slow, admitted-but-OOM'd, TTFT-ceiling false rejects).
4. **Account for every "no"** — record every 4xx we return, the parameters that
   triggered it, and **whether the fleet could actually have served it**. The
   point is to find requests we reject that *should* have produced output (false
   429s, unknown-model demand, balance/limit friction) — see §4.9.

Everything here is **non-private operational metadata**. Privacy invariants in §8.

---

## 2. The current algorithm (ground truth we are measuring against)

For each request the scheduler scores every eligible provider and picks the
lowest cost. **Lower cost = better.** From `buildCandidateWithReason`:

```
cost = statePenalty       // slot warmth: running/idle=0, idle_shutdown=20000, cold-load=30000
     + queueMs            // effectiveQueue × 3000
     + pendingMs          // totalPending × 750
     + backlogMs          // tokensAhead / effectiveTPS × 1000
     + thisReqMs          // prompt/prefillTPS×1000 + maxTokens/effectiveTPS×1000
     + healthMs           // memPressure×4000 + cpu×1500 + gpuUtil×5000 + thermal
```

with:

- `effectiveQueue = max(pendingForModel, backendRunning + backendWaiting)`
- `effectiveTPS = observedEWMA → fleetMedian → staticTPS/(1 + 0.27×batchSize)`
- `tokensAhead = activeTokenBudgetUsed + queuedTokenBudget` (token-budget providers)

**Selection** then: take the min-cost candidate, build a **near-tie pool**
(within `nearTieCostWindowMs = 3000`), tie-break by `effectiveQueue`, then
`totalPending`, then random; a `cacheAffinityBonusMs` can pull a sticky provider
in; `PreferOwner` filters to owned machines; `AvoidVersion` filters the retry
pool.

**Gates** run *before* cost (any failure drops the candidate):
status / trust / slot-state / thermal-critical / trait gates → vision gate →
hardware-fit gate (`modelFitsHardware`, prefers catalog `min_ram_gb`, else
`weightGB × 2.0`) → free-memory admission gate (`freeMemoryAdmits`, uses
`kvCacheBytesPerToken`).

**Known structural mismatch:** the coordinator's `freeMemoryAdmits` is *less*
conservative than the provider's own `ensureModelLoaded` (which demands
`estimatedMemoryGb × 3.0` headroom). So the coordinator can admit a request the
provider then refuses/OOMs. We currently cannot measure how often this happens.

Every constant and fallback above is a **calibration target**. The data model in
§4 is designed so each one has a column (or derived metric) that tells us whether
it is right.

---

## 3. Data architecture

Four tables, written best-effort and async so they never add request latency.

| Table | Grain | Purpose |
|-------|-------|---------|
| `inference_routes` | one row per **request attempt** (the winner + outcome) | Explain the chosen machine; predicted-vs-actual; retry chains. **(Phase 0 — already built.)** |
| `request_rejections` | one row per **rejected inbound request** (4xx/5xx, at any stage) | The **"what are we saying no to"** ledger — captures rejections that never reach routing (auth, validation, balance, rate-limit, pre-flight), each with a counterfactual *could-we-have-served-it* snapshot. **(Phase 1 — the new ask.)** |
| `inference_route_candidates` | one row per **(attempt × candidate provider considered)** | The per-candidate scores — *why the winner won and the losers lost*. **(Phase 2.)** |
| `provider_capacity_samples` | one row per **provider heartbeat snapshot** (sampled) | Time-series of fleet state independent of requests; calibrate TPS/health decay. **(Phase 3 — optional but high value.)** |

A key realization: `inference_routes` only sees requests that **reached routing**.
Most 4xx (auth, validation, unknown-model, balance, rate-limit, pre-flight 429)
are returned *earlier* and are invisible today. `request_rejections` closes that
hole and is the answer to "what are we saying no to, and what could have actually
resulted in an output?"

`inference_routes.id` is the parent key for `inference_route_candidates`.
`(request_id, attempt)` correlates everything for one dispatch.

### 3.1 Where it's stored & how the data flows

```
 inference request                       admin / analyst
        │                                       ▲
        ▼                                       │ read
┌───────────────────┐   write (async,    ┌──────┴───────────────┐
│ coordinator        │   best-effort)     │  GET /v1/admin/routes │  JSON (filtered)
│  • dispatch.go     ├───────────────────▶│  GET /v1/admin/...    │  + CSV/NDJSON export
│  • recordRejection │   store.Store iface │      /export          │  (download)
└───────────────────┘        │            └──────────────────────┘
                             ▼
                    ┌──────────────────┐
                    │ PostgresStore     │  inference_routes
                    │ (store/postgres)  │  request_rejections
                    └──────────────────┘  inference_route_candidates …
```

- **Write side:** the coordinator already holds every datum in memory at decision
  time (`Provider`, `RoutingDecision`, `pr.Timing`, the request struct). We write
  it through the existing `store.Store` interface — `dispatch.go` for routes,
  `handleComplete` for outcomes, a new `recordRejection(...)` helper for 4xx.
  All writes are `saferun.Go` async + timed-out, so a DB hiccup never touches the
  request path.
- **Storage backend — the prerequisite:** the store is chosen at boot in
  `cmd/coordinator/main.go:83-108` by **`EIGENINFERENCE_DATABASE_URL`**:
  - set → **PostgresStore** (durable; what we want).
  - unset → in-memory store, and the process **refuses to start** unless
    `EIGENINFERENCE_ALLOW_MEMORY_STORE=true`. In-memory means the data is **lost
    on every restart/deploy and is not queryable** (`docs/operations/dev-environment.md:208`).
  - **Therefore: this telemetry is only useful where Postgres is enabled.** Dev
    already wires Cloud SQL (`dev-environment.md:153`). Prod (EigenCloud) must have
    `EIGENINFERENCE_DATABASE_URL` set — confirm before relying on the data. This is
    the single gating dependency for the whole effort.
- **Read side:** admin-authed HTTP — a filtered JSON view *and* a streaming
  **CSV/NDJSON download** for offline analysis (spreadsheet / notebook / DuckDB).
  Details in §6.

---

## 4. Every data point — and what each one is *for*

This is the core of the plan. Each datum is tagged with the algorithm question or
constant it lets us answer/calibrate. **Bold = not yet captured (gap to add).**

### 4.1 Identity & correlation (`inference_routes`)
| Field | Why we collect it |
|-------|-------------------|
| `request_id`, `attempt` | Correlate decision → outcome → candidates; reconstruct retry chains across machines. |
| `provider_id` | The machine that won (empty if none). |
| `model`, `public_model` | Per-model calibration; alias-vs-build analysis. |
| `consumer_key_hash`, `key_id` | Per-tenant load patterns, abuse/hot-key detection. Hashed, never raw. |

### 4.2 The decision & its scoring (the winner's cost terms)
All already in `inference_routes`. These are the **predicted** numbers.
| Field | Calibrates / answers |
|-------|----------------------|
| `outcome` (`selected`/`queued`/`no_provider`/`model_too_large`/`ttft_429`/`error`) | Decision-class distribution; how often we reject vs route vs queue. |
| `cost_ms` (total) + `state_ms`,`queue_ms`,`pending_ms`,`backlog_ms`,`this_req_ms`,`health_ms` | The exact cost decomposition of the winner. Lets us see which term dominated the choice. |
| `ttft_ms`, `best_ttft_ms` | Predicted TTFT of winner + best available; validate vs `actual_ttft_ms`; Retry-After accuracy. |
| `effective_tps`, `static_tps` | The TPS the model *assumed*; compare to measured decode TPS → calibrate `effectiveTPSLoadFactor` and the fallback chain. |
| `effective_queue`, `candidate_count` | Load spread; how many real options existed. |
| `capacity_rejections`, `model_too_large_rejections`, `vision_rejections`, `ttft_rejections` | The aggregate "mismatch" — why candidates were dropped. Drives capacity planning + ceiling tuning. |

### 4.3 The winner's hardware/runtime snapshot (the machine's numbers)
All already in `inference_routes`. These are the **inputs** the cost used.
| Field | Calibrates / answers |
|-------|----------------------|
| `provider_status`, `provider_trust_level`, `provider_version` | Does trust/version correlate with failures? Per-version regression detection. |
| `hardware_chip`, `hardware_chip_family`, `hardware_tier`, `memory_gb`, `gpu_cores`, `cpu_cores` | **The grouping key for all calibration.** TPS, load-factor `k`, and headroom must become per-tier, not global. |
| `system_memory_pressure`, `system_cpu_usage`, `system_thermal_state` | Validate the health penalties (`×4000`, `×1500`, thermal) — do they actually predict slowdown? |
| `gpu_memory_active_gb`, `gpu_memory_peak_gb`, `gpu_memory_cache_gb` | Validate the `gpuUtil×5000` penalty and the memory-admission gate. |
| `slot_state` | Validate `statePenalty` (cold-load 30000 / idle_shutdown 20000). |
| `backend_running`, `backend_waiting` | Batch size at decision time → the x-axis for the TPS-decay curve. |
| `active_token_budget_used`, `active_token_budget_max`, `queued_token_budget` | Validate `backlogMs`; calibrate token-budget admission. |

### 4.4 Request shape (`inference_routes`)
| Field | Calibrates / answers |
|-------|----------------------|
| `estimated_prompt_tokens`, `requested_max_tokens` | Inputs to `thisReqMs`/`backlogMs`; compare estimate vs actual `prompt_tokens`. |
| `requires_vision`, `has_tools`, `self_route_only`, `prefer_owner` | Per-shape routing behaviour; vision/tools capacity. |
| `cache_affinity_key` | Measure cache-affinity bonus efficacy (hit → faster?). |

### 4.5 The outcome (what actually happened) — `inference_routes`
| Field | Calibrates / answers |
|-------|----------------------|
| `final_status` (`success`/`error`/`timeout`/`cancelled`) | Reliability per machine/model/version. |
| `error_code`, `error_class` (`client_gone`,`queue_timeout`,`insufficient_funds`,`provider_error`,`encryption_missing`,`first_chunk_timeout`,`accepted_timeout`,`preamble_liveness_timeout`) | Failure taxonomy; which failure modes dominate. |
| `prompt_tokens`, `completion_tokens`, `reasoning_tokens`, `cost_micro_usd` | Actual work done; estimate accuracy; cost-per-token by tier. |
| `actual_ttft_ms`, `dispatch_to_first_chunk_ms`, `total_duration_ms` | **The ground truth.** `actual_ttft_ms − ttft_ms` = TTFT prediction error. `total_duration_ms` vs predicted `cost_ms` = cost-model error. |

### 4.6 Gaps to ADD to `inference_routes` (Phase 1)
| **New field** | Why it matters |
|-----------|----------------|
| **`parse_ms`, `reserve_ms`, `route_ms`, `encrypt_ms`, `queue_wait_ms`, `dispatch_ms`** | The `X-Timing` decomposition is computed per request and returned in a header but **thrown away**. This is our coordinator-side overhead budget — needed to separate "our latency" from "provider latency". Cheap: already on `pr.Timing`. |
| **`actual_queue_wait_ms`** | We store the queue *penalty estimate* (`queue_ms`) but not the *measured* wait (`EnqueuedAt → dispatch`). Without it we cannot validate the queue penalty. |
| **`actual_decode_tps`** | Measured decode TPS for the completed request (`completion_tokens / decode_time`). The single most important calibration signal vs `effective_tps`. |
| **`used_backup`, `backup_won`** | Speculative/backup-race dispatch happens (`raceBackupErrWaitPrimary`) but its win/loss is invisible. Tells us if speculation helps. |
| **`provider_region`, `consumer_region`** | "Closest machine" reasoning; geo-aware routing later. (Provider geo from registry; consumer geo already GeoIP-bucketed for usage.) |
| **`admitted_but_failed`** (bool) + `provider_reported_free_gb` | Detect the coordinator-admits / provider-OOMs mismatch (§2). Calibrates `kvCacheBytesPerToken` and the 2.0-vs-3.0 headroom gap. |
| **`prefix_cache_hit`, `prefix_cache_hit_tokens`** | Whether the provider actually reused KV/prefix cache. Validates cache-affinity routing. (Requires one new optional field on the provider `complete` message — only protocol touch in the whole plan, and it's additive.) |
| **`is_final_attempt`, `total_attempts`** | Make retry chains queryable without window functions. |

### 4.7 Per-candidate scores — `inference_route_candidates` (Phase 2, the new ask)
One row per provider the scheduler *considered* for an attempt. This is what lets
us answer "why this machine and not that one," and run **counterfactual /
regret** analysis.

| Field | Why |
|-------|-----|
| `route_id` (FK → `inference_routes.id`), `request_id`, `attempt` | Link to the parent decision. |
| `provider_id`, `rank` (0 = winner) | Identify each candidate and its finishing position. |
| `selected` (bool) | Was this the winner? |
| `eligible` (bool), `rejection_reason` (`capacity`/`model_too_large`/`vision`/`ttft`/`thermal`/`trust`/`slot_state`/`none`) | **Why a candidate lost before scoring** — the per-machine mismatch. |
| `cost_ms` + full breakdown (`state_ms`,`queue_ms`,`pending_ms`,`backlog_ms`,`this_req_ms`,`health_ms`,`ttft_ms`) | The loser's score, term by term. "A won at 1.2s, B was 1.35s (its `backlog_ms` was 2× higher)." |
| `effective_queue`, `effective_tps`, `static_tps`, `batch_size` | The loser's live state — needed to know if the model *correctly* ranked it. |
| hardware snapshot (`chip_family`, `tier`, `memory_gb`, `slot_state`, mem pressure, thermal, gpu active) | Compare winner vs loser hardware; detect "we picked a worse machine." |
| `cache_affinity_applied` (bool), `affinity_bonus_ms` | Did affinity change the ranking? |

**Counterfactual value:** once we have outcomes *and* candidates, we can ask: when
the winner was slow/failed, **would the runner-up have been faster?** If the #2
candidate consistently beats the #1 we picked, the cost model is mis-ranking and
we know exactly which term to fix. This is the highest-leverage analysis in the
whole plan and is impossible without per-candidate rows.

### 4.8 Fleet time-series — `provider_capacity_samples` (Phase 3, optional)
Sampled heartbeat snapshots (e.g. 1/min/provider), independent of requests:
`provider_id`, `ts`, hardware tier, `backend_running`, `backend_waiting`,
`observed_decode_tps`, `active_token_budget_used/max`, mem pressure, cpu, thermal,
gpu active/peak/cache, `warm_models`, `current_model`, `slot_states`.
Purpose: build the **TPS-vs-batch-size decay curve per hardware tier** (the
`effectiveTPSLoadFactor` calibration) and the health-vs-throughput correlation
from clean, evenly-sampled data instead of request-biased data.

### 4.9 Rejection & lost-demand — `request_rejections` (the "what are we saying no to")

`inference_routes` only captures requests that reached routing. This table
captures **every rejection on the inference path**, with the request's parameters
*and* — critically — **whether the fleet could actually have served it** ("what
could have resulted in an output"). The funnel, grounded in code:

| Stage | HTTP | `reason_code` (examples) | Code |
|-------|------|--------------------------|------|
| `auth` | 401/403 | `missing_credentials`, `invalid_api_key`, `invalid_privy`, `key_disabled`, `forbidden` | `server.go:1949-2077` |
| `validation` | 400/413/422 | `messages_required`, `malformed_json`, `bad_param`, `payload_too_large`, `unsupported_param` | `consumer.go:1470-1484,1774` |
| `model_resolution` | 404/503 | `model_not_found`, `model_unavailable`, `alias_unresolved` | `consumer.go:1506,1632,4085` |
| `balance` | 402 | `insufficient_quota` (per-key cap), `insufficient_funds` (account), `insufficient_funds_provider_price` | `consumer.go:1604-1611,4135-4142,4426` |
| `rate_limit` | 429 | `rpm_exceeded`, `itpm_exceeded`, `otpm_exceeded`, `global_rate_limit` | `server.go:525,568,2174` |
| `preflight_capacity` | 429/503 | `machine_busy` (all full), `no_provider` (none serve model), `model_too_large` | `consumer.go:1658-1714,4168-4204` |
| `routing_ttft` | 429 | `ttft_429`, `queue_timeout` (also in `inference_routes`) | `dispatch.go:358-473` |

**Request shape & params (non-private — no content):**
`request_id`, `endpoint`, `ts`, `key_id`/`consumer_key_hash`, `client_class`
(e.g. openrouter vs direct, from user-agent), **`requested_model` (RAW as sent —
captures typos / unknown names)**, `resolved_model` (or empty), `stream`, `n`,
`estimated_prompt_tokens`, `requested_max_tokens`, `requires_vision`, `has_image`,
`has_audio`, `has_tools`, `tool_count`, `response_format` (e.g. json_schema),
`self_route_only`, `prefer_owner`, a `params` JSON blob of **non-content** knobs
(temperature, top_p, penalties, stop-count…), `request_body_bytes`, plus
`stage`, `http_status`, `reason_code`, `retry_after_ms`.

**Counterfactual servability — "could it have produced output?"**
The pre-flight *already* calls `QuickCapacityCheckWithTTFTForRequest`
(`consumer.go:1658,4168`), which returns this exactly. For rejections that happen
*before* pre-flight (auth/validation/balance/rate-limit) we run the same cheap,
read-only fleet scan at rejection time:
| Field | Meaning |
|-------|---------|
| `could_have_served` (bool) | `candidate_count_at_reject > 0` — **the headline signal** |
| `candidate_count_at_reject`, `capacity_rejections_at_reject`, `model_too_large_at_reject`, `vision_rejections_at_reject` | The fleet picture at the moment we said no |
| `warm_provider_existed` (bool) | Was the model already resident somewhere? |
| `best_ttft_ms_at_reject` | For `ttft_429`: how close to the ceiling were we? |
| `shortfall_micro_usd` | For 402: required − available (the *amount*, never the balance) → lost revenue |
| `limit_kind`, `over_by` | For 429 rate-limit: which limit and by how much → legit-burst signal |

This makes every "no" answerable — *was it necessary?*
- 429 with `could_have_served=true` → **false rejection** (we had capacity; a limit or ordering bug blocked it).
- 404 unknown `requested_model` → **pure demand** for something we don't serve / an unresolved alias.
- 402 with a warm provider available → **lost revenue** blocked only by balance/top-up friction.
- 400 with `requested_max_tokens` > model cap → **fixable param/UX issue**, not real incapacity.

---

## 5. How we use the data to improve the algorithm

Concrete analyses, each tied to a constant/decision in §2:

1. **TTFT model calibration.** Plot `actual_ttft_ms` vs predicted `ttft_ms`,
   grouped by `hardware_tier × model × batch_size`. Fit per-tier correction.
   → fixes the `prefillTPS = decodeTPS×4.0` and `sqrt(bandwidth)` guesses.
2. **Decode-TPS / load-factor `k`.** Regress `actual_decode_tps` against
   `batch_size` per tier/model. The slope *is* `effectiveTPSLoadFactor`. Today
   `k=0.27` is a single global constant measured on Qwen-7B; replace it with a
   measured `k[tier][model]` table for our real models (`gpt-oss-20b`,
   `gemma-4-26b`) — a 20B/26B will decay very differently from the 7B it was tuned on.
3. **Queue / pending penalty validation.** Correlate `actual_queue_wait_ms` and
   `total_duration_ms` with `effective_queue` and `total_pending`. If the real
   marginal cost of one queued request ≠ 3000 ms, retune `queueDepthPenaltyMs`.
4. **Admission-gate calibration.** Count `admitted_but_failed` by tier/model →
   derive the true `kvCacheBytesPerToken` and whether to raise the coordinator's
   2.0× headroom toward the provider's 3.0×.
5. **Health-penalty validation.** Does high `system_memory_pressure` /
   `thermal_state=serious` actually reduce `actual_decode_tps`? If not, the
   `×4000` / `8000` penalties are over/under-weighted.
6. **Cold-load penalty.** Measure real load latency (slot `unknown` →
   first chunk) vs the flat `30000 ms` assumption; make it size/tier aware.
7. **Cost-model regret (counterfactual).** Using `inference_route_candidates` +
   outcomes: how often did the winner underperform an available runner-up?
   This is the top-line "is the algorithm choosing right" metric.
8. **TTFT-ceiling false-reject rate.** When `outcome=ttft_429`, how often would a
   rejected provider actually have met the SLA? Tune `MaxTTFTMs`.
9. **Cache-affinity efficacy.** Compare TTFT/`prefix_cache_hit` for affinity hits
   vs misses → justify or retune `cacheAffinityBonusMs`.

The next group uses `request_rejections` (§4.9) — the "what are we saying no to":

10. **False-rejection rate.** % of 4xx where `could_have_served=true`. The
    headline "are we needlessly saying no" metric — alert on regressions. A
    rising false-429 rate means a limit or ordering bug, not real saturation.
11. **Lost-demand by reason.** Group rejections by `reason_code × model × tier` →
    decide *what to fix first*: add capacity, raise a limit, load a VLM build, or
    onboard a new model.
12. **Unknown-model demand.** Top `requested_model` values that 404 → models users
    want that we don't serve, and unresolved/typo'd aliases worth aliasing.
13. **Param-driven 400s.** Cluster validation rejections by offending param (e.g.
    `requested_max_tokens` > model cap, unsupported `response_format`) → raise a
    limit or fix the error UX instead of silently losing the request.
14. **Lost revenue.** Sum `shortfall_micro_usd` on 402s where
    `could_have_served=true` → demand blocked purely by balance/top-up friction,
    quantified in dollars.

These start as **offline SQL/notebook analyses** (safe, no production risk). Only
once a recalibration is validated offline do we change a constant — ideally
promoting the worst constants to a config table the coordinator reads, so future
recalibration is a data change, not a redeploy (Phase 4).

---

## 6. Read / analytics path

The data is currently write-only (`InferenceRouteRecordsSince` exists on the
Store but is unwired). Two complementary ways to get it out:

**A. Browse (JSON, paged)** — for quick "why did request X go to machine Y?":
- `GET /v1/admin/routes?since=&provider=&model=&outcome=` (Privy-admin) → recent
  decisions + their candidates.
- `GET /v1/admin/rejections?since=&reason=&model=&could_have_served=` → the "what
  are we saying no to" feed, filterable to just the *false* rejections.

**B. Download (bulk export)** — the simpler path for real analysis, as requested.
Rather than paging a giant JSON reply, **stream the rows straight to a file**:
- `GET /v1/admin/routes/export?since=&until=&format=csv` (also `ndjson`)
- `GET /v1/admin/rejections/export?...&format=csv`
- `GET /v1/admin/candidates/export?...&format=csv`
- Implementation: `Content-Disposition: attachment; filename=...`, a server-side
  cursor (`pgx` row stream / `COPY ... TO STDOUT`) written directly to the
  `http.ResponseWriter` so memory stays flat even for millions of rows. Admin can
  then open it in a spreadsheet, a notebook, or DuckDB (`SELECT … FROM 'routes.csv'`).
- CSV columns mirror the table 1:1; CSV is content-free metadata so it's safe to
  hand to an analyst. (A small `scripts/admin.sh routes export > routes.csv`
  wrapper makes this one command.)

**C. Dashboards / alerting:**
- Canned SQL views (regret, TTFT-error-by-tier, admission-mismatch rate,
  false-rejection rate, lost-demand by model) checked into `docs/architecture/`
  or a `coordinator/datadog/` dashboard.
- Optionally forward aggregates to Datadog (we already have DogStatsD) for
  alerting on regret / mismatch-rate regressions.

---

## 7. Volume, sampling & retention

- `inference_routes`: 1 row/attempt. Fine at current scale; partition by
  `created_at` (monthly) when it grows.
- `inference_route_candidates`: ~`candidate_count`× the routes volume (often
  3–10×). Controls:
  - **Always** store the winner + all *rejected* candidates (cheap, high value).
  - **Sample** the full near-tie pool at, say, 10–25% of requests (configurable),
    or always store top-K (winner + 3 runners-up). Counterfactual analysis only
    needs a representative sample, not 100%.
- `request_rejections`: 1 row/rejection. Volume depends on traffic health; a
  busy/abused coordinator can produce many 401/429. Controls: always log
  authenticated rejections (real demand); **sample anonymous 401/403** (scanner
  noise) and skip pure `malformed_json` 400s where the body never parsed.
- `provider_capacity_samples`: bounded by fleet-size × sample-rate; short
  retention (e.g. 30 days) is enough for curve fitting.
- All writes remain `saferun.Go` best-effort with a short timeout; a telemetry
  outage must never affect inference. Add a global on/off + sample-rate flag.

---

## 8. Privacy & safety invariants (non-negotiable)

- **No prompt or response content, ever.** Only counts, timings, and machine
  metadata.
- Consumer key is **SHA-256 hashed** (`store.HashKey`); raw keys never stored.
- **No raw client IPs.** Geo is coarse-bucketed (city/region), reusing the same
  GeoIP path as the usage table.
- Writes are async + best-effort + timed out (no latency impact, no failure
  propagation).
- Everything is coordinator-internal; the one optional provider-side addition
  (`prefix_cache_hit` on the `complete` message) is a non-sensitive integer.

---

## 9. Phased implementation

> **Prerequisite (gating):** the target environment must run the **PostgresStore**
> (`EIGENINFERENCE_DATABASE_URL` set — `cmd/coordinator/main.go:84`). On the
> in-memory store the tables don't persist and the read/export paths return
> nothing across restarts. Confirm prod (EigenCloud) has the DSN before Phase 1.
> The code itself stays store-agnostic (writes go through `store.Store`), so dev
> with Cloud SQL works today; this is purely an ops switch for prod.

| Phase | Deliverable | Risk |
|-------|-------------|------|
| **0 — done** | `inference_routes` table + two-phase write wired through dispatch/complete; memory+postgres stores; tests green. | shipped on this branch |
| **1** | Add §4.6 gap fields (timing decomposition, actual queue wait, actual decode TPS, admit-but-failed, backup win/loss). **Add `request_rejections` table (§4.9) — the rejection / lost-demand ledger with counterfactual servability.** Add read endpoints (§6). | low-medium — additive columns + a `recordRejection(...)` helper called at each 4xx exit |
| **2** | `inference_route_candidates` table + surface per-candidate scores from `selectBestCandidateLockedFull` (return the scored pool + rejections, not just the winner). Sampling controls. | medium — touches the hot scheduler path; must stay allocation-light and behind the existing `r.mu` |
| **3** | `provider_capacity_samples` from heartbeats; offline calibration notebooks/SQL views; Datadog dashboard. | low — read-only analysis |
| **4** | Promote the worst-fitting constants to a DB-backed `routing_params[tier][model]` config the scheduler reads; close the loop. | higher — changes live routing; gate behind validation + rollback |

---

## 10. Open decisions (need your call)

1. **Candidate sampling rate** — store all candidates always, or sample
   (winner+rejections always, full pool at N%)? Trades storage for completeness.
2. **`provider_capacity_samples`** — build it now (Phase 3) or rely on
   request-driven snapshots only? Cleaner curves vs. more tables.
3. **One protocol touch** — are we OK adding an optional `prefix_cache_hit`
   integer to the provider `complete` message to measure cache efficacy? It's the
   only non-coordinator change in the plan.
4. **Anonymous-rejection logging** — log every 401/403 (complete demand picture,
   but adds scanner/abuse noise and volume), or only authenticated rejections plus
   sampled anonymous ones? Recommended: authenticated always, anonymous sampled.
5. **Counterfactual on every stage** — running `QuickCapacityCheck` on *every*
   pre-pre-flight rejection (auth/validation/balance/rate-limit) is a read-only
   fleet scan but not free under load. Recommended: run it for `balance` and
   `rate_limit` (high-value lost-demand) and reuse the existing pre-flight result
   elsewhere; skip it for malformed/auth-noise.
4. **Calibration target order** — which constant do we attack first? Recommended:
   decode-TPS/`k` (#2) and the admission mismatch (#4), since those cause the most
   visible failures (wrong-machine slowness, post-route OOM).
