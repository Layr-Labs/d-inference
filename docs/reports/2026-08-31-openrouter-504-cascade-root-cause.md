# OpenRouter 504/429 Cascade — Root Cause Analysis

> Last updated: 2026-08-31 · commit `5d400cf75`

**Date:** 2026-08-31 (incident ongoing at time of writing, ~18:10 UTC)
**Scope:** All public models; OpenRouter-visible uptime collapse
**Author's data sources:** `inference_routes` on prod primary (read-only SELECTs from the coordinator VM), live coordinator container logs, host sar history, deployed image inspection, PR #787 diff.

## Executive summary — do this first

**Roll the coordinator back to the pre-#787 image (`b234b9460`) or hot-fix out the `qwen3-vl-30b-a3b-instruct` entry in `coordinator/modelpolicy/first_content_deadline.go`.** The env knob cannot save you: the exact-model policy is a *tightening ceiling* (`if base > exact.coordinator { base = exact.coordinator }`), so no `EIGENINFERENCE_TTFT_LIVE_DEADLINE_BASE_MS` value can loosen the 4s cutoff. The fallback container `coordinator_fallback_20260831-015637` (image `b234b9460`) is already staged on the VM. If rollback is unacceptable because OpenRouter's 5s SLA for qwen3-vl is real, the alternative stop-the-bleed is to shed qwen3-vl entirely (fast 429 at admission, which is failover-neutral for OpenRouter uptime) until providers actually honor cancels.

Root cause in one paragraph: PR #787 (deployed 02:19:32 UTC) gave `qwen3-vl-30b-a3b-instruct` a live 4s first-content cutoff while the model's real production TTFT tail is far above it (pre-deploy success p90 = 5.2s, p95 = 6.5s; 11.6% of pre-deploy *successes* exceeded the new clock). The cutoff is live enforcement in the dispatch path — **independent of `EIGENINFERENCE_TTFT_ADMISSION_MODE=shadow`**, which only governs the pre-dispatch admission gate. The coordinator therefore kills a large fraction of in-flight qwen3-vl dispatches at ~4s. The kill sends a WebSocket cancel, but providers do not reliably stop generating: engines keep producing for already-abandoned requests ("zombie generation"). Killed requests are retried by OpenRouter (each 429 re-fired at us), multiplying load. The damage went fleet-wide through three measured paths (§4): zombie qwen3-vl work starving other models on shared machines, retry amplification raising every model's load against shrinking capacity (attempts nearly doubled; even providers with no qwen3-vl doubled their timeout rate), and provider churn taking whole machines — all their model slots — offline. Under this load the fleet destabilized (mass provider churn, dispatch-into-dead-socket 502s, queue timeouts), successes collapsed from ~140K/h to ~23K/h, and everything OpenRouter sees is either our fast 429 or their own gateway 504 on requests that stayed silent.

## Timeline (UTC, Aug 31)

| Time | Event |
|---|---|
| Aug 30 all day | Baseline: ~80-100K successes/h; coordinator 504s ~1.5-3.9K/h (attempts); qwen3-vl already the worst model (~13-14% 504-attempt rate in its pre-deploy traffic bursts, 9s clock) |
| 01:22 | PR #787 merged (model-specific first-content deadlines; qwen3-vl → 4s live cutoff) |
| 01:56 | Deploy swap begins (fallback container staged with prior image `b234b9460`) |
| 02:00-02:19 | Swap/drain window served by the old 9s-clock coordinator; qwen3-vl 504s already elevated in this sliver (attribute to swap churn + a concurrent qwen3-vl traffic burst, **not** the 4s clock — it wasn't running yet) |
| **02:19:32** | **New coordinator (`2d737d87e`, #787) starts. Coordinator 504 attempts jump ~7x within the hour (1.2K/h → 8.1K at 02:00, 9.7K at 03:00, climbing to 14K/h)**; qwen3-vl request-level 504 share reaches ~40-50% |
| 02:00→11:00 | Death spiral builds: qwen3-vl request volume roughly triples (much of it OpenRouter re-firing our 429s — 4.4M our-side requests vs ~2.6M their-side over the window); other models' 504s rise ~3x; client_gone rises from ~7K/h to 15-22K/h |
| 12:04:50-12:11:27 | First mass 502 wave: 19,001 in-flight requests die `provider_error`, terminal on first attempt, no retry, across 316 providers — **a fleet-wide provider upgrade rolling through in restart cohorts** (see "The 502 waves — RESOLVED"); the same upgrade's trust collapse (#778) strands cohorts unroutable |
| 12:40-13:00 | Second upgrade wave (zero request-id overlap with the first); 332 provider IDs never route again after 12:00, 375 new IDs appear |
| 14:00 | OpenRouter derates us: volume dips to ~90K/h |
| 15:00-present | Thundering-herd return + collapse: 300-430K attempts/h, successes 23-27K/h, 429 `queue_timeout` appears (30K/h), 502 "failed to send request to provider" 45-55K/h, ~560 provider disconnects/h, 65K zombie chunks per 10 min |

## Evidence

### 1. The deployed change and its clock

Running image: `coordinator:2d737d87e6ca0bb46871ac9013f06adca55b04a2` = PR #787, container started 02:19:32Z (verified via `docker inspect`).

`coordinator/modelpolicy/first_content_deadline.go` (new in #787): qwen3-vl-30b-a3b-instruct gets `4s + 1ms/token` live coordinator cutoff (vs ordinary `9s + 1ms/token`). `Server.FirstContentDeadline` feeds this to `dispatchOneProvider` and the first-token clock (`first_token_clock.go`), which **abandons in-flight dispatches** (`abandonInflightForFirstTokenTimeout`): route row recorded as 504/`first_chunk_timeout`, provider excluded, WS cancel sent, and the exhausted ladder reclassifies the synthetic 504 to a retryable **429** for the caller (`classifyExhaustedStatus`, dispatch.go:710).

The running container has `EIGENINFERENCE_TTFT_ADMISSION_MODE=shadow` — but shadow only disables the *admission* 429 gate. The first-token clock kill path is unconditional. #787 effectively took a 4s hard deadline live for qwen3-vl while the admission telemetry said "shadow."

### 2. The 4s clock cannot fit this model's real TTFT

Pre-deploy (Aug 29 02:00 → Aug 31 02:00) qwen3-vl successful-request TTFT: p50 1.43s, **p90 5.19s, p95 6.53s**. 11.6% of 65,032 pre-deploy *successes* had `actual_ttft_ms > 4000 + estimated_prompt_tokens`, i.e. would be killed by the new clock even with zero added load. Post-deploy "success" TTFT p90 clamps to 3.35s — survivorship, not improvement.

Post-deploy 504 route rows by class (02:40→17:40): `first_chunk_timeout` = 107,486 qwen3-vl, 36,926 qwen3.5-35b, 32,827 gpt-oss-20b, 23,439 gemma-4-26b — all models rose, qwen3-vl dominates.

### 3. Kills don't stop provider work (the amplifier)

Coordinator logs, one 10-minute window at ~18:00 UTC:

```
41,975  inference request dispatched
 2,115  inference complete
65,772  WARN  chunk for unknown request     (309 distinct providers)
 6,272  WARN  error for unknown request
 2,151  WARN  complete for unknown request  (= full generations for abandoned requests)
14,467  WARN  provider failed, retrying
 1,924  ERROR chunk buffer overflow — failing request
```

Providers stream chunks — and entire completions — for requests the coordinator abandoned. `handleCancellation` (ProviderLoop+Cancellation.swift) is defense-in-depth (registry token + `engineV2Runtime.cancel` + task cancellation), but every path no-ops if the request isn't yet registered (no tombstone for early cancels), and once first content is emitted the pre-content deadline checks stop applying — a request killed by the coordinator at 4.0s whose first frame landed at 3.9s runs to completion (requested max_tokens averaged 10-21K on the affected cohorts, i.e. minutes of decode). Which seam leaks how much is not fully adjudicated; the log volume proves the phenomenon at scale.

### 4. Why other models degraded (three paths, measured)

Post-deploy, other models' timeout-ish rate (504 + client_gone over that plus successes) rose from 10.5% to 20.9-27.7%. Three mechanisms, in measured order:

**(a) Shared machines (partial).** 275/1,031 gemma providers, 235/904 gpt-oss providers, and 235/512 qwen3.5 providers also served qwen3-vl post-deploy. On those shared providers other models ran worse (27.7% timeout-ish, TTFT p90 7.1s) than on providers with no qwen3-vl (20.9%, p90 6.4s): zombie qwen3-vl decode occupies engine batch rows and Metal time, pushing other slots' prefill out.

**(b) Fleet-wide load amplification (the bigger share).** Even providers that never served qwen3-vl doubled their timeout-ish rate (10.5% → 20.9%). Every coordinator kill and shed comes back as an OpenRouter retry (4.4M our-side requests vs ~2.6M client requests), and each of those fans out internally at ~3-5 attempts; hourly attempts rose from ~170-200K to 280-430K against a *shrinking* effective fleet. All models share the same coordinator queue, dispatch ladder, and OpenRouter retry pressure, so every model's TTFT tail crossed its own 9s clock more often.

**(c) Fleet destabilization takes whole machines out for all their models.** Provider disconnect churn (~560/h), the 12:00+ mass-502 waves, and dispatch-into-dead-socket failures cost capacity indiscriminately; a provider that drops takes its gemma and gpt-oss slots down with its qwen slots.

Caveat: provider IDs are reminted on reconnect (the deploy's WS drop reset most of them), so the pre/post shared-cohort comparison relies on post-deploy IDs only; hardware-level attribution would tighten (a) vs (b) but not change the ordering.

### 5. Fleet destabilization

- ~94 provider disconnects + 92 websocket read errors per 10 min (fleet ~500-650): providers cycling roughly hourly.
- Current-hour 502s are `"failed to send request to provider"` — dispatch into dead/closing provider sockets, retried up to 5 attempts, then `dispatch_exhausted`.
- 429 `queue_timeout` (30K/h) appeared once the coordinator queue itself saturated.
- Host is healthy (60% idle, no iowait at the worst moments; coordinator ~5 cores of 30) — this is capacity collapse, not coordinator saturation.

### 6. What OpenRouter sees (reconciliation)

- Their **504s (335K)** ≈ our request-level `client_gone` (~316K over the same window): their gateway timing out our still-silent requests — same mechanism as the 2026-08-24 report, now at 12x scale.
- Their **429s (192K)** ≈ our deadline-kill/queue/capacity 429s (request-level coordinator-504-reclassified ≈ 226K; some overlap lands as their 504 instead when their clock expires first).
- Their ~2.6M total vs our 4.4M requests on their key: their failover layer retries our retryable statuses against us (we're the only provider for these models) and records one final status per client request. Our terminal 503s are absorbed by that retry loop, which is why their dashboard shows only 8 × 503.
- Successes collapsed (their success avg 82K/h; last full hours ~23-27K/h our side) → uptime metric tanks → they derate our traffic (hour-14 dip), then return in herds (hour-15 spike), worsening the oscillation.

### 7. Selection-lock saturation — confirmed as the collapse-phase mechanism, not the trigger

A separate investigation attributed the incident to saturation of the global provider-selection lock (`ReserveProviderEx` takes the registry-wide `r.mu.Lock()` at scheduler.go:399 and holds it through `selectBestCandidateLockedFull`'s scan of every connected provider at :658; all models share it). Code confirmed. Telemetry adjudicates it as **phase 2, not phase 1**:

| Window | attempts/h | route_ms p50 | dispatch p95 | Incident state |
|---|---:|---:|---:|---|
| Aug 30 baseline | 155-226K | 32ms-1.2s | ~1.2-1.3s | healthy |
| 02:19-11:00 (post-#787) | 123-320K | **32-292ms** (1.2s once, at the 07:00 volume peak) | 1.4-1.6s | 504 kills already at 8-14K/h, qwen3-vl ~50% killed, OpenRouter dashboard already red |
| 15:00-18:00 (collapse) | 207-470K | **3.5s / 6.0s / 6.9s / 5.5s** | 6-7s | successes 6-9%, 429s at ~13.2s median vs OpenRouter disconnect ~13.5s |

Selection was sub-second for the first nine hours of the incident while OpenRouter's 504/429 wall was already fully formed — so lock saturation cannot be the root cause. But in the collapse phase it is exactly the proximate mechanism the other investigation measured: with median selection at 6.9s, every request burns its first-content budget pre-dispatch, providers refuse `deadline_unreachable`, the retry ladder re-enters the same lock 3-5x, and the terminal 429 lands ~300ms after OpenRouter has already hung up. The load that saturated the lock is the retry storm the #787 kills generated (4.4M their-key requests vs ~2.6M client requests; herd return after their hour-14 derate). The lock handled 200-226K attempts/h fine on Aug 30.

Consequence: fixing only the lock leaves the qwen3-vl kill machine and its retry amplification running; rolling back #787 removes the load source, after which the lock should un-saturate at baseline volume. Both fixes are worth doing — rollback first, selector scalability (shard the lock, move the scan to a read lock / snapshot, or bound selection retries) as a follow-up so a future burst cannot re-enter this mode.

## The 502 waves — RESOLVED: fleet-wide provider upgrade + trust collapse (second root cause)

The 12:04:50-12:11:27 and 12:40-13:00 waves (and the churn thereafter) are a **routine fleet-wide provider upgrade** rolling through the fleet, per PR #778 ("coordinator: survive fleet upgrades without trust collapse", merged 17:57 UTC as incident remediation). Two harms:

1. **In-flight deaths in restart waves.** Upgrading providers restart in cohorts; their in-flight requests die as terminal `provider_error` 502 on first attempt with no retry — matching the burst shape exactly (19,001 requests, deaths spread over a 6.5-min rolling window, discrete waves, zero request-id overlap). Routes data shows 332 provider IDs stopped routing after 12:00 while 375 new IDs appeared (restart re-mints IDs).
2. **Trust collapse strands cohorts unroutable.** Reusable trust was keyed on `(SE key, serial, binary_hash)`; the upgrade changed `binary_hash` everywhere at once, the whole fleet missed the trust-reuse cache simultaneously, and the synchronized live MDM `SecurityInfo` wave hit Apple's push throttling (~2-3/hr/device) and timed out — leaving genuine hardware stranded at `self_signed`, which selection excludes. This capacity loss is invisible in `inference_routes` (unroutable providers simply vanish) but was observed directly by the #778 authors. #778 splits device evidence from binary evidence and is coordinator-only (hotswap-deployable).

This leg is independent of #787 — but it landed on a fleet already degraded by zombie load, and the capacity it removed is what pushed the retry storm over the selection-lock wall two hours later.

## Root-cause ranking

1. **#787's 4s live cutoff for qwen3-vl** — direct trigger; live despite shadow admission mode; kills ~half that model's requests under load.
2. **Cancel-not-honored zombie generation** — the amplifier that turned one model's mis-set deadline into fleet-wide capacity loss. This was always latent (client_gone requests also zombie); the kill rate made it dominant.
3. **OpenRouter retry amplification** — every fast 429 comes back as a new request; 4.4M vs 2.6M.
4. **Fleet-wide provider upgrade at ~12:00 UTC** (independent second root cause) — restart waves killed in-flight requests (the 502 bursts) and the trust-collapse bug (#778) stranded cohorts unroutable, shrinking capacity under an already-elevated retry load.
5. **Global selection-lock saturation** — the proximate mechanism of the 15:00+ collapse (median selection 3.5-6.9s, 429s losing the race to OpenRouter's disconnect by ~300ms); a pre-existing wall, hit standalone on Aug 26 (route p50 2.7-4.3s at 405-468K attempts/h, 18-40K client_gone/h, self-recovered when volume fell). Downstream of 1-4 today.
6. **Herd oscillation from OpenRouter's derate/return cycle** — deepens the collapse phases.

## Does merging #793 + hotswap fix it? (asked 2026-08-31 ~19:00 UTC)

Partially — it fixes two of the three legs and leaves the original trigger armed:

| Leg | Fixed by the proposed hotswap? |
|---|---|
| A. #787's 4s qwen3-vl kill machine + zombie amplification (02:19-11:00 damage, sub-second routing) | **No.** #787 is still in master; the new image re-ships the 4s clock. When OpenRouter re-ramps qwen3-vl after seeing recovery, the OpenRouter-visible 429/504 wall on that model returns — phase 1 proved this needs no lock saturation. Add the one-line modelpolicy revert (or shed qwen3-vl) to the same swap. |
| B. Fleet-upgrade trust collapse + restart churn | **Yes (trust side)** — #778 is merged and coordinator-only. The in-flight-death-on-upgrade behavior and the provider-side cancel bug remain (provider release needed). |
| C. Selection-lock wall (~300K attempts/h; Aug 26 precedent) | **Yes** — #793's two-phase reservation (concurrent RLock scans, short revalidated write commit) is the right shape; the commit path re-runs identity, snapshot, candidate, TTFT-ceiling, and admission gates before debiting, so overbooking is guarded. Watch the optimistic-retry budget (2 attempts, then routing-failure → 429/queue path) under thundering bursts: concurrent scans converge on the same deterministic winner, so expect some commit-conflict churn; a conflict-rate metric would tell. |

Ship-risk notes for the swap itself:
- **Master CI is red right now** (coordinator/store code-attest scheduler tests, failing on master at `7c23eab71`+ — the same failures show on #793's CI, i.e. inherited, most likely from #778's store changes, not #793). Resolve or explicitly accept before building; re-check the prod build preflight (trigger provenance was hand-fixed 2026-08-03, never codified).
- **#792 rides along** — a large fresh-state-capacity/hedging routing feature merged mid-incident at 18:04 UTC. It targets real evidence (stale heartbeat budgets, herding) but is un-battle-tested; it ships in the same image whether or not you want it to. Plan to watch its metrics or consider whether this swap should be cut from a branch holding only #778+#793+#787-revert.
- The hotswap restart itself drops all provider WS connections and in-flight state — expect a brief dip, then relief that is partly the restart, not the fix; judge the fix by whether route_ms p50 stays low at 300K+ attempts/h.

## Recommended actions

Immediate (human approval required per prod policy — I have not executed anything):
1. Roll coordinator back to `b234b9460` (staged fallback container) — or deploy a one-line hotfix deleting the qwen3-vl entry from `exactFirstContentDeadlineBases`. Rollback restores the pre-incident steady state: qwen3-vl alone degraded (~13% timeout in its bursts), no spiral.
2. If qwen3-vl's OpenRouter 5s SLA is real and binding, shed the model at admission (fast 429, failover-neutral) rather than killing mid-flight. A 4s mid-flight kill is the worst of both worlds: the work is wasted *and* the fleet keeps paying for it.
3. After stabilization, ask OpenRouter to reset/re-probe (their derate lags recovery).

Follow-up bugs to file:
1. **Provider: honor cancel during generation** — tombstone cancels for unregistered request ids; enforce an absolute generation abort when the coordinator abandons; verify `CBv2Engine.cancel` latency under saturated batches. (The `complete for unknown request` counter is the regression metric.)
2. **Coordinator: model-specific deadlines must not be "tightening ceilings" only** — an operator needs an env override to loosen/disable an exact-model policy without a deploy.
3. **First-token clock should not run tighter than admission believes** — in shadow admission mode, a model-specific *live* kill clock going out in the same PR is a footgun; couple them or alarm on kill-rate per model.
4. **Still unfiled from 2026-08-30:** #704/#787 deadline-admission cold-start wedge (one pathological first prefill sample seeds `isolatedPrefillTpsEwma`; refusals record no new samples; slot wedges until reload).
5. **Pull Datadog logs for 12:04-12:12 UTC** to identify the 502-wave provider error text.
6. **Selector scalability** (§7): shard or read-lock the provider scan in `ReserveProviderEx`, and bound deadline-driven re-selection so a retry storm cannot drive median selection latency into the first-content budget. Baseline capacity ~226K attempts/h is demonstrably fine; ~300K+/h is not.

## Methodology / safety

All DB access was read-only SELECTs (`default_transaction_read_only=on`, 30s statement timeout) executed from the coordinator VM per operator instruction. No prod state was mutated. Log inspection used `docker logs` snapshots into `/tmp` on the VM. Queries and intermediate SQL are in the session scratchpad (`sql/00-09`).
