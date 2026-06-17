# Routing v2 — admit by measurement, serve all the compute, never ship bad streams

Status: **in progress** (this branch: `routing-v2`). Tracks the redesign of the
coordinator's admission/routing/autoscaling so we (a) stop rejecting requests the
fleet can serve, (b) use all eligible compute, and (c) never hand users degraded
(low-tok/s) streams.

PR #381 (soft TTFT gate + prefill ×12 + kill-switch) is the first slice and is
included as the base of this branch.

---

## 1. Why (measured, prod `api.darkbloom.dev`, ~67 min window)

- **~71% of chat/completions are 429'd** (HTTP counters: 9,804×200 vs 23,837×429).
  **97.9% of rejections are `ttft_too_slow`; 100% had `could_have_served=true`;
  `machine_busy`=0.** Not a capacity problem.
- **Acceptance cliff at ~550–650 prompt tokens** (served p95 prompt=611; rejected
  median=1,576). Cause: TTFT gate estimates prefill as `decode×4 ≈ 100 tok/s`
  while the deadline (`5s+1ms/tok`) implies ~1,000 tok/s. **No provider reports a
  measured prefill rate**, so the ×4 fallback is the production path.
- **Utilization ~12–19%**: 137 routable, 90 warm, 16 active, 0 queued, token
  budget 99.94% free. 84% of served requests went to **idle (warm)** providers.
- **gemma decode anomaly**: gemma-4-26b-qat-4bit and gpt-oss-20b are **both
  4-bit, both ~4B-active MoE**, both served at batch ~0, yet gemma decodes at
  **~21 tok/s vs gpt-oss ~69**. 21 tok/s ≈ a **dense 26B** read (~13GB/token);
  69 ≈ a ~4B-active read (~2GB/token). **gemma is being decoded as if dense — its
  expert sparsity is not exploited.** ~3× recoverable, and gemma is 63% of demand.

### What the data plane is missing today
- Prefill rate is guessed (`decode×4`), never measured.
- The TTFT ceiling is a **hard pre-dispatch reject**, not a routing preference.
- Cold providers (~33% of routable) are never dispatched (fixed 20–30s penalty).
- No **per-request sustained-decode floor** in admission (only memory/concurrency
  caps + a TTFT *first-token* gate). A naive "serve everything" would overpack.
- The warm-pool controller is **blind to the preflight rejects** (97.9% of them):
  `RecordWarmPoolTTFTMiss` is only called post-dispatch, never from the preflight
  429. Its ramp is also slow (1 load / 30s, 4 max-pending, 5m dwell).

---

## 2. Objective

Maximize served **paid** throughput **subject to a per-request quality floor**
(sustained decode ≥ floor; TTFT within SLA where physically possible), using all
eligible compute. Never reject work a quality-passing provider can serve; shed
(429) **only** on measured saturation, with an honest Retry-After.

It is a constrained optimization implemented as three layers: **measure → decide
per request → shape capacity.**

---

## 3. Layer 1 — Measurement (provider monitors = the inputs)

Every routing input becomes a measurement. Per-slot, EWMA, in the heartbeat
(must stay aligned across `coordinator/protocol`, `provider-swift` telemetry, and
`console-ui/src/lib/telemetry-types.ts` — see AGENTS.md sync points):

| field | purpose |
|---|---|
| `observed_prefill_tps` | kills the ×4/×12 guess; exact TTFT |
| `observed_decode_tps` (exists) + **`decode_knee`** | per-request decode vs batch B → know how many concurrent before quality drops |
| `observed_ttft_ms` | measured first-token latency |
| `model_load_time_ms` | real cold-start per model → safe cold dispatch |
| active batch / queue depth / free KV / free RAM / thermal | mostly exist |
| `active_params` / model class | compare observed decode to hardware expectation → auto-flag a model served below class (the gemma case) |

`decode_knee` representation is an open question (single degradation coefficient
vs small (batch→tok/s) table). Start with: report `solo_decode_tps` +
`decode_degradation_coeff` (default 0.27, the current `effectiveTPSLoadFactor`).

---

## 4. Layer 2 — Data plane (per-request decision, hot path)

For request `(model M, prompt P, max_tokens, traits)`:

1. `deadline = 5s + 1ms·P` (SLA contract, unchanged).
2. `candidates` = providers serving M passing all gates (trust, attestation,
   privacy, freshness, traits) **and** with a free concurrency slot.
3. Per candidate, from monitors compute **projected per-request decode** (at
   batch+1) and **projected TTFT** (measured prefill/decode; + measured
   `model_load_time` if cold).
4. **Quality filter**: keep candidates where projected decode ≥ `DECODE_FLOOR`
   (default ~15 tok/s). *This is the "no shit responses" constraint.*
5. **Select** the quality-passing candidate that serves fastest, biased toward
   filling a warm provider toward its knee before warming a new one
   (consolidation/utilization). Dispatch. **TTFT over deadline is a preference
   for faster, never a reject** (PR #381).
6. **If none pass the floor**, in order:
   a. **cold-dispatch**: load M on the fastest idle cold node (pay measured load
      once → it becomes warm);
   b. **brief queue**: bounded wait; a completing request restores batch
      headroom; re-admit on slot-free;
   c. **shed (429)**: only if all providers are at concurrency/KV cap, no cold
      capacity, and the queue is full — honest Retry-After.
7. Keep existing mechanics: speculative TTFT-aware backup race, failover on
   provider error, exactly-once commit, stream.

One line: **serve on the fastest warm provider that stays above the quality
floor; else grow warm capacity; else queue; shed only when truly saturated.**

---

## 5. Layer 3 — Control plane (capacity shaping, ~per tick)

1. Estimate per-model demand λ (arrival EWMA) and service time E[S]
   (prefill+decode).
2. **Little's Law target**: `target_warm = ceil(λ·E[S] / quality_concurrency) +
   burst_buffer`, where `quality_concurrency` = max batch keeping decode ≥ floor
   (from the knee).
3. Drive the warm pool to target: proactively warm cold providers, evict past
   min-dwell, **ramp fast enough to track λ** (today's 1-load/30s is too slow).
4. Feed **every** pressure signal — including preflight near-misses and shed
   events — into λ/target.
5. **Capacity unlock**: fix code-attestation churn (retry/backoff, longer
   challenge freshness, cache across reconnect) so trusted machines stay routable
   (~120 trusted machines currently locked out of the routable pool).
6. **Throughput anomaly detector**: flag any model decoding below its
   active-param class (auto-detects the gemma-dense bug) → alert / prefer faster
   build.

---

## 6. Guardrails / invariants

- Never reject a request a quality-passing provider can serve. *(acceptance)*
- Never dispatch below `DECODE_FLOOR`. *(quality)*
- Shed only on measured saturation, honest Retry-After. *(truthful backpressure)*
- Keep busy/KV, privacy, trust, attestation gates hard. *(safety)*
- Optional **SLA-tail cap**: for prompts so large even a perfect provider can't
  meet TTFT (e.g. >8k tok), allow a hard cap if protecting the SLA metric matters
  more than serving — tunable.

## 7. Parameters (env tunables)

- `EIGENINFERENCE_TTFT_HARD_REJECT` (default false — soft) — already in #381.
- `EIGENINFERENCE_PREFILL_DECODE_RATIO` (default 12) — already in #381.
- `EIGENINFERENCE_MIN_DECODE_TPS` (decode floor, **default 15 — quality bar ON by default**; set 0 to disable) — new.
- warm-pool: target buffer, ramp rate, min-dwell, cold-dispatch threshold.
- queue bound; SLA-tail cap threshold.

---

## 8. Before / after (trace-driven sim, exact prod stream, quality-protected ≥15 tok/s)

| | accept @1× (today) | @2× | @4× | gemma per-req | <15 tok/s |
|---|---|---|---|---|---|
| BEFORE (current hard ×4) | 28% | 28% | 28% | — | — |
| AFTER routing+floor (gemma as-is 21) | 100% | 94% | 65% | ~17–23 | 0% |
| AFTER + gemma MoE fix (→~69) | 100% | 100% | 100% | ~41–79 | 0% |

Calibration: the sim's CURRENT run reproduces the observed 71.6% reject and the
~550–650 cliff, which validates the model. Sim lives in
`coordinator/.../routingsim` (see workstream W7) — port of the prototype in
scratch (`/tmp/sim*.py`).

---

## 9. Workstreams (status + dependencies)

| ID | Workstream | Area | Depends on | Status |
|----|-----------|------|-----------|--------|
| W0 | Soft TTFT gate + prefill ×12 + kill-switch | coordinator | — | **DONE (PR #381)** |
| W1 | Provider monitors: `observed_prefill_tps`, `model_load_time_ms` (protocol + provider-swift + TS mirror + symmetry tests) | protocol/provider/ui | — | **DONE** (measured EWMA prefill + model load time on BackendSlotCapacity). **Now consumed by routing**: `resolvePrefillTPS(snap)` = observed → benchmark → ×12, used in `ttftMsFromSnapshot` (no-op until providers report it post-release). `observed_ttft_ms` + `decode_knee` deferred. |
| W2 | Decode-floor admission + quality filter (`EIGENINFERENCE_MIN_DECODE_TPS`) | coordinator scheduler/consumer | W1 | **DONE** (soft preference: `projectedPerRequestDecodeTPS` unwinds measured decode at batch→solo→batch+1; `MinDecodeTPS` on PendingRequest; default off; never fails closed). The hard quality guarantee — spill when ALL candidates are below floor — lands with W3. |
| W3 | Cold-dispatch spill + queue-before-shed | coordinator consumer/dispatch | W2 | **DONE** (queue-before-shed routes capacity-rejects into the dispatch queue; cold-dispatch spills `no_provider` to a warming idle provider via TriggerModelSwaps; all preflight reject/soft-serve paths now feed `RecordWarmPoolCapacityReject`/`RecordWarmPoolTTFTMiss`+`triggerWarmPool`. Flags `EIGENINFERENCE_QUEUE_BEFORE_SHED`/`EIGENINFERENCE_COLD_DISPATCH` default true.) |
| W4 | Warm-pool rebuild (Little's Law, all-signal, faster ramp) | coordinator registry/warm_pool | W1 | **DONE** (`warm_pool_target.go`: target = ceil(L/quality_concurrency)+buffer, L = running+waiting+queue+spillArrivalRate·E[S]; spill-arrival EWMA finally surfaces the shed demand; demand-scaled ramp. New knobs: `DECODE_FLOOR_TPS`, `BURST_BUFFER`, `RAMP_GAP_FRACTION`, `MAX_LOADS_PER_TICK_CEILING`, …) |
| W5 | Attestation-churn unlock (retry/backoff, freshness, cache) | coordinator attestation/provider | — | **Fixes 1/2/3/4/5/6 DONE.** Fix 6 observability; Fix 1 read-loop verification (late/reconnect attest, fail-closed); Fix 3 mode-aware backoff+jitter; Fix 4 freshness 6m→16m; Fix 5 expiry/timeout→300s; **Fix 2** APNs token in heartbeat (re-arm on late/changed token, fail-closed: token never grants trust) + reuse-cache persistence behind the store seam (version-gated/windowed). **Only Fix 0 (`APNS_MODE=alert`) remains = human config flip.** See routing-v2-attestation-churn.md |
| W6 | gemma MoE decode fix (confirm dense-vs-sparse, fix MLX path) + benchmark tooling | provider-swift / mlx | — | **investigated** (`darkbloom benchmark --sweep` shipped; provider-swift/docs/gemma-decode-bandwidth-analysis.md). gemma ~21 tok/s == dense-26B bandwidth (~13GB/tok) vs ~142 sparse expectation; Swift gathers sparsely, so root cause is **MLX 4-bit `gatherQuantizedMM` small-batch path** (smoking gun: 4-bit ~21 < 8-bit ~74) + gemma's always-on dense FFN. Fix is MLX/submodule-level — run sweep on a real box to confirm, then patch the 4-bit expert gather. |
| W7 | Trace-driven sim → committed Go CI replay harness (drives real scheduler; calibration regression test) | coordinator test infra | — | **DONE** (coordinator/registry/routingsim: ×4 cliff 601, ×12 cliff 2384, soft-gate serves all) |
| W8 | Throughput anomaly detector (decode vs active-param class) | coordinator telemetry | W1 | **DONE** (`throughput_anomaly.go`: expected = bandwidth·eff/(active_params·bytes); periodic fleet sweep emits `routing.throughput_anomaly{model,chip}` via ddIncr + `/v1/admin/metrics`. Live: flags gemma-4-26b-qat-4bit ratio 0.15, not gpt-oss 0.44. Env-tunable thresholds.) |

Conflict map: W2/W3 both touch `consumer.go`/`dispatch.go` (sequence together).
W4 is mostly `warm_pool_controller.go`. W1 is the shared protocol contract (do
early; delicate 3-language sync). W5/W6/W7 are independent areas (parallelize).

## 10. Rollout / safety

- Every change ships behind a flag, default-safe; soft behaviors are reversible
  without rebuild.
- **W7 is the safety net**: replay real traces against the real scheduler in CI
  so any routing change is validated (acceptance + per-request decode floor +
  TTFT) before deploy. No routing change merges without a green replay.
- Sequencing: #381 → W7 (harness) + W1 (monitors) → W2 (floor) → W3/W4 →
  W5/W6/W8. **No deploys by the agent** — human applies (EigenCloud/GCP).

## 11. Open questions

- `decode_knee` wire format (coeff vs table).
- Select cost function: weight of TTFT vs consolidation/packing.
- Queue-vs-cold-dispatch ordering (latency vs capacity-growth).
- SLA-tail policy: serve-slow vs hard-cap for >8k-token prompts.
- Decode floor default (15? per-tier?) and whether it's per-model.
