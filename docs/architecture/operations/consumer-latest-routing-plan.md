# Consumer-Latest Routing Plan

Date: 2026-06-14

Worktree: `.worktrees/consumer-latest-routing`

Branch: `plan/consumer-latest-routing`

## Objective

Deliver the best consumer experience under burst and sustained load: requests should reach capable providers whenever the fleet can serve them, TTFT should stay low, per-request decode TPS should stay healthy, long-budget requests should not be rejected solely because they requested worst-case output, and the coordinator should widen warm capacity when direct pressure shows the current warm set is insufficient.

## Core Diagnosis

- The largest observed load-test failures are pre-router admission failures, not provider selection failures.
- Balance reservation debits one hot Postgres balance row before routing; OpenRouter-style service traffic concentrates on one account row.
- OTPM admission charges full bounded `max_tokens` before routing; long-budget reasoning requests get rejected even when actual output would fit.
- Current warming is too reactive: it looks at queued demand and only warms when there is no warm provider at all.
- A single warm provider can soak traffic while many cold-capable providers stay idle because routing correctly prefers warm slots but no separate controller expands the warm pool.
- Prefix/SSD KV cache has an explicit request-level `prompt_cache_key` scope. It can be used for soft routing affinity, but it must stay separate from warm-pool control.
- Prod deploy freshness is ambiguous. `/health` does not expose coordinator commit/version, making load-test interpretation harder after several days without redeploy.

## Design Principles

- Use direct pressure signals, not speculative forecasts.
- Optimize user-visible performance, not provider utilization. The system should optimize two consumer SLOs: time to first content (TTFT/TTFC) and sustained output TPS. The controller should react to consumer pain: queue wait, time-to-first-content, decode TPS degradation, retries/failover, and cold-start exposure.
- Keep routing and warm-pool control separate. Routing picks the best provider for this request; the controller decides whether to add warm capacity for a model.
- The warm-pool controller only changes warm targets and sends bounded `load_model` commands. It must not change token budgets, balance admission, or request rate limits.
- Cache affinity is a routing optimization only. It must not drive the warm-pool controller.
- Prefer simple hysteresis over complex prediction: require pressure to persist before warming, add capacity in small steps, and stop adding when pressure clears.
- Do not force-unload in the first pass. Let provider idle timeout handle decay; the coordinator target only controls new load commands.
- Every warm action must pass the same safety gates as routing: model catalog, trust, private-text support, challenge freshness, runtime verification, cooldowns, memory fit, private-only exclusion, and thermal safety.
- Warming must be non-interfering. Do not send `load_model` to a provider with active inference, and keep global concurrent loads low so model loading does not hurt active consumers on other machines through fleet-wide resource contention.
- Routing should prefer providers that preserve both fast first content and good decode TPS. A warm but heavily saturated provider should lose to another eligible provider when the expected per-request TPS or backlog makes consumer experience worse.

## Non-Goals

- Do not port the existing `.worktrees/predictive-warming` branch as the main design. It can be mined for tests or small helpers, but the controller should be simpler.
- Do not redesign billing ledger semantics for every consumer in the first pass.
- Do not add prompt content logging or persistent prompt fingerprints.
- Do not require provider protocol changes for the first cache-affinity implementation.
- Do not hard-pin public traffic to any provider.

## Code Evidence

- Preflight balance reservation runs before routing in `coordinator/api/consumer.go:1452` and `coordinator/api/consumer.go:3956`.
- Postgres balance debit updates a single account row in `coordinator/store/postgres.go:1781`.
- Output-token rate limiting admits on upfront `max_tokens` in `coordinator/api/server.go:375`.
- Provider-reported KV bytes per token exists in `coordinator/protocol/messages.go:208`.
- Coordinator fallback KV sizing still uses `kvCacheBytesPerToken` in `coordinator/registry/scheduler.go:39` and `coordinator/registry/scheduler.go:752`.
- Dispatch selection is `ReserveProviderEx` in `coordinator/registry/scheduler.go:213`.
- Fast preflight is `QuickCapacityCheck` in `coordinator/registry/scheduler.go:1079`.
- Queue-driven reactive warming is `TriggerModelSwaps` in `coordinator/registry/registry.go:2339`.
- Capacity snapshot currently sets warm from a running slot in `coordinator/registry/registry.go:3803`.
- Provider extracts `prompt_cache_key` or `user` as cache scope in `provider-swift/Sources/ProviderCore/ProviderLoop+InboundDecode.swift:80`.
- Provider token-level checkpoint digests are computed after tokenization in `provider-swift/Sources/ProviderCore/KVCache/PrefixDigest.swift:25`.

## Current Control Knobs And Feedback Paths

This is the concrete control surface the implementation should use. New code should add to these loops rather than invent separate hidden loops.

Queue loop:

- Knobs: per-model queue size `10`, wait `120s` in `coordinator/registry/registry.go:784`; retry hint from `estimateRetryAfter` in `coordinator/api/consumer.go:918`.
- Signals: queue depth, oldest queued age, queue timeout, queue full.
- Actuators: enqueue/reject, drain queued requests, warm-pool target/load commands.

TTFT/speculation loop:

- Knobs: `ttftDeadline = 5s + 1ms/input_token`, speculative backup at `0.5 * deadline`, preamble-content timeout, inference idle timeout in `coordinator/api/consumer.go:44`.
- Signals: first-content time, speculative backup started, speculative backup won, first-content timeout, accepted-then-stall timeout.
- Actuators: retry/failover for this request, warm-pool pressure for future requests.

Admission loop:

- Knobs: request RPM/service RPM and ITPM/OTPM defaults in `coordinator/ratelimit/config.go:38`; per-key overrides in API-key records.
- Signals: token/RPM rejects, service-account balance reservation failures, capacity preflight rejects.
- Actuators: request reject, expected-output token admission, service-account deferred reservation. Admission changes must stay separate from warm-pool control.

Routing/capacity loop:

- Knobs: queue/pending/backlog/health/cold-load cost terms in `coordinator/registry/scheduler.go:16`; provider token-budget caps from heartbeat; trust and freshness gates.
- Signals: candidate count, capacity rejection count, effective TPS, token backlog, warm saturation, thermal state.
- Actuators: provider selection for this request; warm-pool pressure events for future capacity.

Model-load loop:

- Knobs: `pendingModelLoadTTL = 2m`, drain backoff `30s`, dispatch-load cooldown `2m` in `coordinator/registry/registry.go:757`.
- Signals: `load_model_status` success/failure, load duration, dispatch load failure, pending-load count.
- Actuators: send bounded `load_model`, clear/backoff pending load, reject unservable queue.

Freshness/safety loop:

- Knobs: challenge freshness `6m` in `coordinator/registry/scheduler.go:37`, heartbeat-derived `BackendCapacity`, thermal gates.
- Signals: heartbeat slot states, observed decode TPS, active token budget, challenge freshness, provider thermal state.
- Actuators: deroute, skip warming target, capacity snapshot.

Rollout loop:

- Knobs: new feature flags must default off for service reservation, expected-output OTPM, warm-pool active mode, and cache affinity.
- Signals: health version, feature mode tags, per-track metrics.
- Actuators: observe-only mode first, per-service-account enablement, then broader rollout.

## Track A: Pre-Router Admission Reliability

Owner profile: coordinator API + store engineer.

Goal: service-account traffic should not return `503 service_unavailable` because many concurrent requests all pre-debit the same balance row.

Plan:

- Add coordinator build/version metadata to `/health` first so canaries prove what code is deployed.
- Introduce a trusted service-account reservation mode behind an env flag, initially for `store.RoleService` only.
- In service-account reservation mode, skip the synchronous preflight `ledger.Charge` hot-row debit and reserve against an in-memory per-account outstanding cap refreshed from the store.
- Charge actual usage at settlement and keep full immediate debit behavior for normal consumer accounts.
- Bound exposure with per-account outstanding caps, request TTL cleanup, and fail-closed behavior if cached available balance cannot be refreshed.
- Keep provider-specific price top-up paths consistent with free self-route and service-account reservation mode.

Files likely touched:

- `coordinator/api/consumer.go`
- `coordinator/api/dispatch.go`
- `coordinator/api/server.go`
- `coordinator/store/postgres.go`
- new `coordinator/api/reservations.go`

Tests:

- Concurrent service-account preflight does not call `Debit` per request and does not emit `503` under artificial slow store.
- Normal consumer preflight still debits synchronously and still rejects insufficient balance.
- Service-account settlement charges exactly once on success and cleans outstanding holds on provider error, client cancel, timeout, and speculative loser.
- Provider custom price top-up does not reintroduce the hot-row path for service accounts.

## Track B: Expected-Output Token Admission

Owner profile: rate-limit + API engineer.

Goal: OTPM protects the platform without rejecting long-budget requests solely because `max_tokens` is large.

Plan:

- Extend token limiting to admit on estimated output tokens and reconcile actual completion tokens afterward.
- Start with service accounts enabled by env flag; keep full `max_tokens` charging for normal consumers until validated.
- Add `OutputAdmissionEstimator` in `coordinator/api`: estimate = bounded fraction of `max_tokens` with floors and model-specific override hooks.
- Reconcile actual output after completion. If actual output exceeds estimate, consume the delta from the same token limiter so later requests slow down.
- Keep billing reservation separate; this track changes rate-limit admission, not billable usage.

Files likely touched:

- `coordinator/api/server.go`
- `coordinator/api/consumer.go`
- `coordinator/api/dispatch.go`
- `coordinator/ratelimit/*`

Tests:

- Service account with `max_tokens=32768` no longer immediately exhausts the 512k burst purely from 16 concurrent admissions.
- Actual completion above estimate reduces future output-token capacity.
- Reconciliation is idempotent across streaming, non-streaming, provider error, and timeout paths.
- Per-key OTPM overrides still apply.

## Track C: Pressure-Based Warm-Pool Controller

Owner profile: registry/scheduler engineer.

Goal: if directly observed pressure shows a model's warm pool is too small, warm more eligible providers before users experience queue timeouts or repeated cold starts.

Controller model:

- State is per model: current warm count, current running count, current idle-loaded count, target warm count, oldest queued age, recent capacity-reject count, recent first-content SLO miss count, recent decode-TPS SLO miss count, recent speculative backup win count, and warm saturation count.
- Signals come from direct events only:
  - Queue depth and oldest queue age.
  - Capacity rejects from preflight and dispatch selection.
  - Warm saturation: warm eligible providers with no concurrency or token-budget headroom.
  - User-visible time-to-first-content pressure: route+queue+dispatch time before first content.
  - User-visible decode throughput pressure: recent requests whose post-first-content tokens/sec is below the model/provider floor.
  - Provider-reported decode TPS degradation: warm slots whose observed TPS falls materially below their own recent baseline while they are running multiple requests.
  - TTFT deadline misses, speculative backup launches, and speculative backup wins.
  - Cold dispatches selected by routing.
  - Measured `load_model` duration and recent request service time, used only to calibrate wait estimates and rollout dashboards.
- EWMA may smooth noisy counters, but no historical baseline or demand forecast is required.
- Output is only `targetWarmCount` and bounded `load_model` actions.

Pressure rules:

- Severe pressure: oldest queued age exceeds a small threshold, or capacity rejects occur while cold eligible providers exist. Add one warm target immediately, subject to caps.
- Sustained pressure: warm saturation, first-content SLO misses, decode-TPS SLO misses caused by loaded-slot saturation, speculative backup wins, or cold dispatches persist for N ticks. Add one warm target.
- No pressure: keep target stable for a minimum dwell time, then let it decay by one target step. Do not force-unload.
- Emergency guard: never warm more than the configured per-model step, global step, or eligible idle provider count in one tick.

Warm target selection:

- Candidate must be routing-safe, public-eligible, idle, not private-only, not in pending-load or dispatch-load cooldown, not critical thermal, and must fit the model by catalog/hardware gates.
- Candidate must have zero active requests across all loaded models. A warm-up action should never compete with an active consumer on that Mac.
- Prefer candidates with more free memory/headroom, lower GPU memory pressure, better observed/static TPS, lower thermal state, fewer loaded pressured models, and no recent load failures.
- Do not steal a provider from another model that is currently pressured unless no other option exists.
- Respect `maxModelSlots`; providers may hold multiple models, but the controller should avoid churn by enforcing a minimum model dwell time.

Consumer-performance guardrails:

- Warm-pool changes should be judged by first-content latency and retry behavior, not just more warm providers.
- Warm-pool changes should also be judged by sustained output TPS. If adding warm capacity spreads load and improves per-request decode TPS, keep it; if it only adds churn, back off.
- A load command is a means to reduce future consumer wait or preserve output throughput. If warming raises TTFT misses, decode-TPS misses, speculative wins, provider OOMs, or load failures, the controller should back off.
- Prefer warming models with active consumer pain over models with merely high request rate.
- Avoid chasing long generations: a high number of active long decodes is not itself pressure if first-content SLO is healthy, decode TPS is healthy, and the queue is empty.

Files likely touched:

- new `coordinator/registry/warm_pool_controller.go`
- new `coordinator/registry/warm_pool_state.go`
- `coordinator/registry/config.go`
- `coordinator/registry/registry.go`
- `coordinator/registry/scheduler.go`
- `coordinator/cmd/coordinator/main.go`
- `coordinator/api/consumer.go`
- `coordinator/api/dispatch.go`
- `coordinator/api/provider.go`

Tests:

- One warm saturated provider plus cold eligible providers raises target and sends one bounded `load_model`.
- Fast capacity rejects record pressure and can raise target even when no request entered the queue.
- Queue age pressure raises target; empty queues with no misses do not.
- First-content SLO miss or speculative backup win contributes pressure without requiring p95 aggregation.
- Decode-TPS SLO miss contributes pressure only when it coincides with warm saturation or low observed TPS under multi-request load; a slow model/provider baseline alone does not raise target.
- Active long-running decodes alone do not raise target when queue age, capacity rejects, first-content misses, and decode-TPS misses are zero.
- Controller skips private-only, untrusted, stale challenge, dispatch-load-cooled, critical thermal, active, and pending-load providers.
- Controller picks the better idle provider by headroom/TPS/thermal, not map iteration.
- Target does not oscillate when demand alternates between two models; minimum dwell and no-steal rules hold.

## Track D: Scheduler And Capacity Correctness

Owner profile: registry correctness engineer.

Goal: preflight, capacity snapshot, and actual dispatch should agree, and operators should see true warm/cold state.

Plan:

- Treat slot state `idle` as loaded everywhere, including `freeMemoryAdmits` and `QuickCapacityCheck` snapshots.
- Fold vision requirement into preflight capacity so media requests do not pass text-only capacity checks.
- Add thermal-critical exclusion to `QuickCapacityCheck`; preserve serious/fair as cost penalties unless warm target selection skips them.
- Update `/v1/models/capacity` to count both `running` and `idle` as warm, and optionally expose `running_providers` separately.
- Emit `routing.cost_ms`, `routing.effective_decode_tps`, and cost breakdown tags for the main chat dispatch path, not only generic paths.
- Add consumer-visible decode TPS metrics from first content to completion where usage is available. Use these for observability and warm-pool pressure, not for billing.
- Review candidate cost terms so saturated warm providers are penalized enough to protect both first-content and decode TPS. Keep the cost model explainable: queue/backlog/this-request/health terms should remain decomposable.
- Replace fixed cold penalties with measured load ETA only if that can be done from direct recent load durations; otherwise keep conservative defaults and rely on the warm-pool controller.

Files likely touched:

- `coordinator/registry/scheduler.go`
- `coordinator/registry/registry.go`
- `coordinator/api/consumer.go`
- `coordinator/api/dispatch.go`
- capacity handler files

Tests:

- `idle` resident slots are admitted under memory fallback.
- Vision preflight returns no candidates when only text providers are eligible.
- Critical thermal provider does not count as preflight capacity.
- Capacity snapshot warm count includes `idle`; running count remains available if added.
- Chat dispatch emits route cost metrics for immediate, queued, retry, and speculative backup win paths.
- Low effective TPS on a saturated warm provider makes another eligible provider win when consumer decode throughput would be materially better.

## Track E: Cache Affinity For Existing Prefix Cache Scope

Owner profile: API + scheduler engineer.

Goal: repeated or conversation-like workloads that explicitly provide `prompt_cache_key` should have a chance to hit provider-local prefix cache without hard-pinning traffic.

Plan:

- Reuse existing request field `prompt_cache_key`; hash it as `SHA256(prompt_cache_key)` to match provider cache scope policy.
- Do not compute token-level `PrefixDigest` in the coordinator in the first pass. That requires provider-equivalent tokenization and chat-template rendering.
- Do not use cache affinity as a warm-pool signal.
- Add an in-memory, TTL-bound `CacheAffinityTracker` keyed by `(accountID, model, cacheScopeHash)`.
- Record the winning provider after a successful first content or completion.
- During candidate selection, apply a small cost bonus when the affinity provider is eligible and not materially slower than the best provider.
- Never bypass normal gates: trust, privacy, serial allowlists, vision/tools, thermal, token budget, cooldowns, and queue/backlog still win.
- Emit metrics for affinity lookup, eligible hit, selected hit, and skipped-too-busy.

Files likely touched:

- `coordinator/api/consumer.go`
- `coordinator/api/dispatch.go`
- `coordinator/registry/scheduler.go`
- new `coordinator/registry/cache_affinity.go`

Tests:

- Same account/model/`prompt_cache_key` softly prefers previous provider when costs are close.
- Affinity does not select a provider that is full, cooled down, text-only for media, below trait floor, private-only, thermally bad, or outside allowlist.
- Different accounts do not share affinity.
- Expired affinity is ignored.
- Requests without explicit `prompt_cache_key` do not get cache-affinity routing by default.

## Track F: Verification, Canary, And Load-Test Harness

Owner profile: verifier/load-test engineer.

Goal: prove consumer experience improved before prod-wide rollout.

Plan:

- Add coordinator commit/version to `/health` and include it in load-test reports.
- Extend load tests to classify pre-router versus router versus provider errors.
- Add direct recent metrics, not sparse percentile aggregation, for:
  - `queue.depth` and `queue.oldest_age_ms`
  - `routing.time_to_first_content_ms`
  - `routing.output_tps`
  - `routing.decode_tps_slo_miss`
  - `routing.capacity_rejects`
  - `routing.ttft_deadline_miss`
  - `routing.speculative_backup_started`
  - `routing.speculative_backup_won`
  - `warm_pool.pressure`
  - `warm_pool.target_warm_count`
  - `warm_pool.actual_warm_count`
  - `warm_pool.load_commands_sent`
  - `routing.cache_affinity_selected`
- Add a gemma mixed-load scenario that asserts warm target and loaded warm count increase under direct pressure.
- Add service-account burst tests for short-output high concurrency and long-budget reasoning concurrency.

Acceptance targets:

- `512 max_tokens x 64 concurrency` service-account burst has zero pre-router billing `503` with idle fleet.
- `32768 max_tokens x 16 concurrency` service-account burst is not rejected solely by upfront OTPM when actual output remains below tier budget.
- Under sustained gemma pressure, warm loaded provider count grows beyond the initial small warm set without queue timeout.
- TTFT deadline-miss rate and speculative-backup-win rate improve or stay flat; no increase in provider OOM/load-failure rate.
- First-content latency improves or stays flat for streaming users; output TPS improves or stays flat for long generations; non-streaming total completion latency must not regress for short requests.
- No privacy regression: no raw prompt logging, no persisted prompt hashes, no cross-account cache affinity.

## Suggested Swarm Split

- Agent A: Track A service-account reservation mode and `/health` version metadata.
- Agent B: Track B expected-output token admission and reconciliation.
- Agent C: Track C pressure-based warm-pool controller.
- Agent D: Track D scheduler/capacity correctness and route-cost observability.
- Agent E: Track E explicit `prompt_cache_key` cache affinity.
- Agent F: Track F tests, load-test scripts, dashboards, and final verification.

## Dependency Order

- Track D should land early because it fixes correctness drift used by the warm-pool controller.
- Track C can start immediately on its own state/controller files, then wire into Track D helpers when available.
- Track A and Track B are independent from scheduler work and should run in parallel because they address the observed OpenRouter-facing failures.
- Track E depends lightly on Track D because it must use the same eligibility/cost model, but it must remain independent from Track C.
- Track F starts immediately with baseline tests and finishes last with integrated load validation.

## Rollout Plan

- Deploy version metadata first or with the first coordinator change.
- Enable service-account reservation mode only for a known test service account in dev.
- Enable expected-output OTPM only for service tier in dev, then one production service account.
- Enable warm-pool controller in observe-only mode first: compute pressure and target, emit metrics, send no `load_model`.
- Enable warm-pool controller with conservative caps: max one load per model per tick, small global load cap, and no forced unload.
- Roll out cache affinity last because it is an optimization, not an availability fix.
- Keep feature flags for service reservation, expected-output OTPM, warm-pool control, adaptive queue behavior, and cache affinity so each can be disabled independently.

## Open Questions For Humans

- What maximum temporary exposure is acceptable for trusted service accounts if preflight debit is deferred?
- Should OpenRouter/service accounts bypass consumer OTPM entirely until expected-output reconciliation is live?
- What direct TTFT/SLO miss threshold should trigger warm-pool pressure for public OpenRouter traffic?
- What minimum recent per-model output TPS should count as consumer-visible decode pressure for public OpenRouter traffic?
- What production env controls are available for enabling warm-pool control independently of deploy?
- Is there a preferred canonical coordinator version source: build-time `git_sha`, Docker label, or EigenCloud revision?
