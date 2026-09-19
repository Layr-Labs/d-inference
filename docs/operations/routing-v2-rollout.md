# Routing flags: kill switches and flag flips

> Last updated: 2026-09-13 · commit `e4df336bc`

This runbook covers the environment variables that disable, retune or
experimentally enable coordinator routing behaviours without a code change.
Account affinity is opt-in and starts off; the tables distinguish defaults
from rollout choices. How the behaviours work is in
[`../architecture/routing.md`](../architecture/routing.md) and
[`../architecture/scheduling.md`](../architecture/scheduling.md); the original
plan is [`../design/routing-v2.md`](../design/routing-v2.md).

## When to use

- A routing regression in production that a single behaviour explains (slow
  streams, queue build-up, provider load churn, attestation churn, noisy
  anomaly alerts) and you need relief before a code fix ships.
- Restoring pre-routing-v2 behaviour for an A/B comparison on dev.

Do **not** use these flags as a substitute for a rollback when the regression
is not explained by one of the behaviours below; roll the binary back per
[`coordinator-deploy.md`](coordinator-deploy.md) → Rollback.

## Prerequisites

- Every flag is read **once at process start**. A flip is an env-file edit
  plus a coordinator restart; follow
  [`coordinator-deploy.md`](coordinator-deploy.md) → "Refresh the env file"
  and "Swap". Production env-file changes and restarts require explicit human
  approval (see [`README.md`](README.md)).
- Validate the flip on `api.dev.darkbloom.xyz` first when time allows.
- Have the Datadog routing dashboards open: `routing.decisions`,
  `routing.hedge_governor_suppressed`, `routing.ttft_admission`,
  `routing.ttft_calibration_ratio`, and the `warm_pool_tick` log stream.

## Steps

1. Identify the behaviour from the symptom table, pick the flag, and confirm
   its current default in code with `rg <FLAG> coordinator/` — the tables
   below cite where each is read.
2. Edit the env file, restart the coordinator, and confirm the startup log
   line for that flag (each flag logs its resolved value at boot from
   `coordinator/cmd/coordinator/main.go`, `coordinator/api/cold_dispatch.go`,
   `coordinator/api/throughput_anomaly.go` or `coordinator/registry/config.go`).
3. Watch the metric named in the row for one observation window before
   deciding whether to keep the flip or revert the binary.

### Core routing

| Variable | Default (code) | Read in | Flip | Effect |
|---|---|---|---|---|
| `EIGENINFERENCE_TTFT_HARD_REJECT` | unset → soft | `coordinator/cmd/coordinator/main.go` (`SetTTFTHardReject`) | `=true` | Restores the legacy hard `429` when every candidate's estimated TTFT exceeds the request's first-content deadline (`ttft_too_slow`). Vision requests are never TTFT-gated. |
| `EIGENINFERENCE_PREFILL_DECODE_RATIO` | `defaultPrefillToDecodeRatio = 12.0` | `coordinator/cmd/coordinator/main.go` → `SetPrefillToDecodeRatio` | `=4` | Pre-v2 prefill estimate for providers that report no measured prefill rate. Shifts TTFT estimates and the `ttft_ceiling` gate for unmeasured providers only. |
| `EIGENINFERENCE_MIN_DECODE_TPS` | `15.0` | `coordinator/cmd/coordinator/main.go` | `=0` | Disables the per-request decode-quality floor (soft pool narrowing; never rejects). Keep on unless the floor is demonstrably starving a model. |
| `EIGENINFERENCE_SERVABILITY_GATE` | on | `coordinator/cmd/coordinator/main.go` (`SetServabilityGate`) | `=false` | Stops the early `429` for structurally unservable long prompts; such requests fall through to queueing and provider-side rejection. |
| `EIGENINFERENCE_LONG_PROMPT_TOKENS` / `EIGENINFERENCE_LONG_PROMPT_PREFILL_WEIGHT` | `0` (off) / `2.0` | `coordinator/cmd/coordinator/main.go` → `SetLongPromptThreshold`, `SetLongPromptPrefillWeight` | set a threshold | Enables the long-prompt fastest-first-token bias ([`routing.md`](../architecture/routing.md#cost-model)). |

### Account-affinity shadow-to-on experiment

Use this procedure only for the opt-in
[account-affinity policy](../architecture/routing.md#account-affinity-and-bounded-spillover).
Obtain explicit human approval for each production env-file change and restart;
the code change itself does not authorize activation.

1. Establish a matched baseline with `EIGENINFERENCE_ACCOUNT_AFFINITY_MODE=off`.
   Record measured p95/p99 first-content latency, 429 and timeout rates, decode
   TPS and retry/hedge amplification over representative concurrent traffic.
2. On dev, set `EIGENINFERENCE_ACCOUNT_AFFINITY_MODE=shadow`; leave
   `EIGENINFERENCE_ACCOUNT_AFFINITY_MAX_TTFT_PENALTY_MS` at the
   [experimental default](../reference/configuration.md#account-affinity).
   Verify unchanged serving decisions, including the existing
   `prefix_affinity` tiebreaker. Check
   [`routing.account_affinity`](../reference/telemetry-inventory.md#account-affinity)
   for counterfactual changes, spill ranks and estimated load-induced delay
   relative to each proposed machine's own idle counterfactual. Shadow does
   not measure the outcomes of its unserved alternatives.
3. Exercise repeated account/model traffic, concurrent requests before a
   heartbeat, reconnects, and overloaded preferred machines. Include an idle
   higher-ranked machine that is inherently slower than its peers: peer speed
   alone must not force spillover. Then add load to that machine and verify
   spillover against its own estimated idle baseline. Confirm that live
   rechecks spill or fall back without waiting on an affinity timer, admitting
   beyond capacity, or introducing an affinity-only 429.
4. After reviewing dev evidence and obtaining approval for the specific
   production rollout, run `shadow` on production before a separately approved
   `on` experiment. Use comparable observation windows and stop the experiment
   if measured tail TTFT, 429s/timeouts, decode TPS or amplification regress.
   The initial load-delay threshold is a hypothesis: an estimated bound does not establish
   an acceptable measured tail-latency tradeoff.
5. If cache benefit is a goal, independently verify authenticated prefix-cache
   participation and measured saved tokens/hit rate using the
   [cache-routing rollout](cache-routing-rollout.md). Account affinity neither
   enables cache reuse nor makes an affinity choice count as a cache hit. Do
   not activate cache routing as a side effect of this experiment.

Rollback this experiment by setting `EIGENINFERENCE_ACCOUNT_AFFINITY_MODE=off`
and restarting through the approved coordinator procedure. Verify affinity
metrics stop and ordinary selection returns; no per-account state needs
purging. Keep cache-routing settings unchanged.

### Queue and cold dispatch

| Variable | Default (code) | Read in | Flip | Effect |
|---|---|---|---|---|
| `EIGENINFERENCE_QUEUE_BEFORE_SHED` | `true` | `coordinator/api/cold_dispatch.go` | `=false` | `machine_busy` preflight rejections are shed immediately as `429` instead of entering the dispatch queue. Watch queue depth and tail latency. |
| `EIGENINFERENCE_COLD_DISPATCH` | `true` | `coordinator/api/cold_dispatch.go` | `=false` | `no_provider` is shed instead of spilling to an idle on-disk provider, and enqueue no longer kicks model swaps. Watch provider load/memory churn. |
| `EIGENINFERENCE_QUEUE_MAX_DEPTH` / `EIGENINFERENCE_QUEUE_MAX_WAIT` | `32` / `120s` | `coordinator/registry/queue.go` | retune | Per-model queue depth and per-request wait bound ([`scheduling.md`](../architecture/scheduling.md#per-model-request-queue)). |

### Warm pool

| Variable | Default (code) | Read in | Flip | Effect |
|---|---|---|---|---|
| `EIGENINFERENCE_WARM_POOL_OBSERVE_ONLY` | `false` | `coordinator/registry/config.go` (`WarmPoolConfig`) | `=true` | Controller keeps planning and logging `warm_pool_tick` but sends no `load_model`. Preferred first step. |
| `EIGENINFERENCE_WARM_POOL_ENABLED` | `true` | `coordinator/registry/config.go` | `=false` | Controller does not run at all; only demand-driven `TriggerModelSwaps` loads models. |
| `EIGENINFERENCE_WARM_POOL_MAX_LOADS_PER_TICK` / `_MAX_LOADS_PER_TICK_CEILING` / `_MAX_GLOBAL_PENDING_LOADS` | `4` / `16` / `16` | `coordinator/registry/config.go` | lower | Slows the ramp; `0` for either loads-per-tick or global-pending is equivalent to observe-only. |
| `EIGENINFERENCE_WARM_POOL_MIN_WARM` | empty | `coordinator/registry/config.go` | `model=n,...` | Pins a per-model warm floor while a demand signal is being debugged. |

The full `WarmPoolConfig` table, including thresholds and Little's-Law
parameters, is in [`scheduling.md`](../architecture/scheduling.md#warm-pool-controller).

### Capacity fault handling

| Variable | Default (code) | Read in | Flip | Effect |
|---|---|---|---|---|
| `EIGENINFERENCE_BUDGET_CLAMP` | on | `coordinator/registry/budget_clamp.go` (`loadBudgetClampConfig`) | `=false` | Stops treating a capacity 503 as proof that a pair's heartbeat budget is stale. `EIGENINFERENCE_BUDGET_CLAMP_TTL_SECONDS` retunes the `5m` fail-open TTL. |
| `EIGENINFERENCE_HEALTH_EJECTION` | on | `coordinator/registry/health_ejection.go` (`healthEjectionEnabled`) | `=off` | Disables stable-identity health ejection; the node-health breaker still applies. |
| `EIGENINFERENCE_CAPACITY_COOLDOWN_THRESHOLD` / `_WINDOW_SECONDS` / `_TTL_SECONDS` / `_MAX_TTL_SECONDS` | `5` / `60` / `120` / `600` | `coordinator/registry/capacity_cooldown.go` | retune | Pair capacity-reject cooldown. |
| `EIGENINFERENCE_CAPACITY_RATE_PENALTY_MS` | `15_000.0` | `coordinator/registry/capacity_rate.go` | `=0` | Removes the gray-box capacity-503 cost penalty. |
| `EIGENINFERENCE_QUALITY_CONCURRENCY_CAP` | `true` | `coordinator/registry/config.go` (`QualityCapConfig`) | `=false` | Reverts to the flat per-provider concurrency cap. `EIGENINFERENCE_QUALITY_CONCURRENCY_OVERCOMMIT` (effective default `1.2`) retunes instead of disabling. |

### Throughput anomaly detector

| Variable | Default (code) | Read in | Flip | Effect |
|---|---|---|---|---|
| `EIGENINFERENCE_THROUGHPUT_ANOMALY_INTERVAL` | `throughputAnomalySweepInterval = 5 * time.Minute` | `coordinator/api/throughput_anomaly.go` | widen | Fewer sweeps. |
| `EIGENINFERENCE_THROUGHPUT_ANOMALY_RATIO` | `DefaultAnomalyRatioThreshold = 0.35` | `coordinator/registry/throughput_anomaly.go` | lower | Flag only deeper shortfalls. |
| `EIGENINFERENCE_THROUGHPUT_ANOMALY_MIN_SAMPLES` | `DefaultAnomalyMinSamples = 3` | `coordinator/registry/throughput_anomaly.go` | raise | Require more samples before flagging. |
| `EIGENINFERENCE_THROUGHPUT_ANOMALY_EFFICIENCY` | `DefaultDecodeEfficiency = 0.80` | `coordinator/registry/throughput_anomaly.go` | — | Fraction of peak bandwidth assumed sustained. |

The detector is observability only; it never changes routing.

### Attestation delivery

| Variable | Default (code) | Read in | Flip | Effect |
|---|---|---|---|---|
| `APNS_MODE` | `background` | `coordinator/cmd/coordinator/main.go` (`loadAPNsAttestor`) | `=alert` | Priority-10 code-identity pushes that are not background-throttled. Safe only while the provider never requests `UNUserNotificationCenter` authorization; see [`../architecture/security/attestation.md`](../architecture/security/attestation.md). Unset to return to `background`. |

Attestation freshness (`challengeFreshnessMaxAge = 16 * time.Minute`) and the
challenge/attest timeouts are compile-time constants, not flags; changing them
is a code change ([`routing.md`](../architecture/routing.md#challenge-freshness)).

### Symptom → flag

| Symptom | First flip |
|---|---|
| Slow or degraded streams admitted | confirm `EIGENINFERENCE_MIN_DECODE_TPS` is not `0`; then `EIGENINFERENCE_TTFT_HARD_REJECT=true` |
| Queue depth / tail latency spike | `EIGENINFERENCE_QUEUE_BEFORE_SHED=false` |
| Provider model-load or memory churn | `EIGENINFERENCE_WARM_POOL_OBSERVE_ONLY=true`, then `EIGENINFERENCE_COLD_DISPATCH=false` |
| Healthy providers stuck gated as `free_memory` | `EIGENINFERENCE_BUDGET_CLAMP=false` |
| Healthy providers stuck gated as `ejection` | `EIGENINFERENCE_HEALTH_EJECTION=off` |
| Long prompts rejected early that providers could serve | `EIGENINFERENCE_SERVABILITY_GATE=false` |
| Attestation problems after switching to alert pushes | unset `APNS_MODE` |
| Anomaly metric noise | raise `EIGENINFERENCE_THROUGHPUT_ANOMALY_MIN_SAMPLES` or lower `_RATIO` |

## Verification

- Startup log shows the flag's resolved value (for example `TTFT hard-reject
  ENABLED via EIGENINFERENCE_TTFT_HARD_REJECT`, `smart servability gate
  DISABLED via EIGENINFERENCE_SERVABILITY_GATE=false`).
- `routing.decisions` outcome mix moves in the expected direction
  (`ttft_too_slow` reappears after enabling hard reject; `no_provider` /
  `machine_busy` rise after disabling queue-before-shed or cold dispatch).
- `warm_pool_tick` logs show `observe_only=true` and `actions=0` after the
  observe-only flip.
- No new `routing.hedge_governor_suppressed` growth attributable to the flip.

## Rollback

Remove the variable from the env file and restart; every default above is the
shipped behaviour. If the symptom persists with the flag flipped, the flag was
not the cause: revert the binary per
[`coordinator-deploy.md`](coordinator-deploy.md) → Rollback rather than
stacking flips.

## Related

- [`../architecture/routing.md`](../architecture/routing.md) — what each behaviour does and the constants behind it.
- [`../architecture/scheduling.md`](../architecture/scheduling.md) — queue, cold dispatch, warm pool.
- [`../architecture/cache-aware-routing.md`](../architecture/cache-aware-routing.md) — `EIGENINFERENCE_CACHE_ROUTING_MODE` (default `off`) and its own rollback rules.
- [`../reference/configuration.md`](../reference/configuration.md) — coordinator environment reference.
- [`coordinator-deploy.md`](coordinator-deploy.md) — env-file refresh, swap, rollback.
- [`../design/routing-v2.md`](../design/routing-v2.md) — the rollout's design and workstream history.
