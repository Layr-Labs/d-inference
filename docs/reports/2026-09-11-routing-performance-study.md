# Routing performance investigation and first allocation fix

> Last updated: 2026-09-11 · commit `7c394fa2b`

Production measurements show request-admission and placement problems larger than the measured coordinator scan overhead. This report separates observed outcomes, incomplete counterfactuals, and a reproduced warm-pool allocation defect. Only the allocation correction is implemented with this report; the broader ranking and cache proposals remain experimental.

## Evidence contract

The deployed coordinator is v0.9.2 at `ef7b5a9aa`; the analysis checkout is `7c394fa2b`. The intervening commit enables provider GPT-OSS caching and is not deployed. Source behavior is checked at the deployed routing implementation. Datadog queries use `env:production,service:d-inference-coordinator`.

The Datadog scorecard uses complete five-minute buckets in **22:25–23:25 UTC**. Request profiles use received-time **23:13–23:28 UTC** and a deterministic 10% request sample. The initial GPT-OSS export hit the 50,000-row cap and was replaced with six status-filtered exports; none of those was truncated. Provider attempts, logical request terminals, accepted cache receipts and provider completion usage are distinct populations. The direct read replica timed out; the request-level data came through the documented authenticated, read-only admin exports.

Committed [aggregate evidence](evidence/routing-performance-20260911/provenance.json) includes raw-artifact hashes and sampling details. Raw request/provider identifiers stay in operator-local artifacts.

## First principles

A useful routing objective is successful delivery within the first-content deadline, followed by sustained decoding quality. An HTTP admission or a successful cache lookup alone is not successful delivery.

Time to first content consists of coordinator preparation, transport, work ahead at the provider, this request's prefill or cache restore, and the first decode step. Remaining decode work matters for completion latency and contention. A maximum output allowance is a memory promise; it is not a measurement of expected output length. KV residency is a memory constraint; it is not necessarily serial decode work that must drain before another request can emit content.

Cache benefit requires an exact compatible prefix, valid identity-bound evidence, an available holder, a restore cheaper than recomputation, and successful execution. Increasing the count of stored prefixes does not by itself prove lower latency. Model residency is another resource allocation problem: warming one model can reclaim another model's idle weights, and that transition must account for active work, user-selected models, load time and future demand.

## Observed network results

| Model | Successful request terminals | Rate-limited terminals | Provider deadline-refusal attempts |
|---|---:|---:|---:|
| Gemma QAT 26B | 124,495 | 1,931 | 75,427 |
| GPT-OSS 20B | 42,511 | 5,362 | 124,239 |
| Qwen 3.6 35B | 6,799 | 950 | 1,066 |
| Qwen 3.5 9B | 1,922 | 487 | 8,524 |
| Qwen 3.5 35B | 1,551 | 7 | 33 |
| Qwen 3.8 27B | 1,203 | 155 | 1,136 |
| Nemotron Lightning | 540 | 249 | 779 |

Source: [Datadog hour aggregates](evidence/routing-performance-20260911/datadog-hour-summary.json). The table omits other terminal classes for readability; the evidence retains them. Attempt refusals can precede a successful retry and must not be added to request failures. These are terminal-event counts, not a joined arrival cohort.

For sampled winning attempts, GPT-OSS first-content latency was 3.35 s median and 10.35 s p95; Gemma was 3.67 s median and 7.66 s p95. GPT-OSS routing scan time was 1.21 ms median and 1.93 ms p95; Gemma was 1.40 ms and 2.23 ms. Time from handler entry to the winning attempt reached 3.55 s p95 for GPT-OSS and 2.96 s for Gemma. That latter interval can include failed earlier attempts; it is not pure coordinator processing time. Source: [profile aggregates](evidence/routing-performance-20260911/profile-summary.json).

The shadow router recorded 170,546 selections with an eligible loaded-idle alternative and 178,130 without one. The signal means a busy winner had an admissible idle peer, not that the peer would have completed faster. The current route scorer accounts for full completion cost and health as well as first-token latency.

## Ranking proposal: test expected work separately from output limits

`coordinator/registry/scheduler.go` (`buildCandidateInto`) uses the requested maximum output tokens in the new request's decode-cost term. Budget-reporting candidates also receive a backlog term derived from active and queued token budgets. Both deserve measurement against actual work rather than a blind constant increase in concurrency.

Among 467 deterministically sampled successful GPT-OSS attempts with a 32,768-token allowance, median engine decode steps were 511; p90 was 2,089 and p99 was 12,442. This is a successful-completion cohort, so it does not establish the output distribution of rejected or failed requests.

An exploratory replay capped only the new request's decode ranking term at 2,048 tokens while leaving all admission constraints and other score terms intact. It changed 1,400 of 2,869 retained GPT-OSS candidate decisions, including 891 moves from busy to idle and 19 moves in the opposite direction. The unchanged-policy replay admits the observed winner for every included row; 14 Gemma rows with a baseline mismatch were excluded. This is a **retained-top-four shortlist replay**, not a full fleet replay or a measurement of hypothetical completion latency. Some changes worsened predicted first-content time, and Nemotron's small cohort did not favor this policy.

Proposal: evaluate an opt-in, model-specific expected-decode horizon and deadline-aware soft preference. Preserve full output reservations and all trust, capacity, context and deadline gates. Require an actual controlled serving comparison before broad enablement. Do not apply a global 2,048-token cap or claim the predicted differences as saved time. [Replay aggregates](evidence/routing-performance-20260911/shortlist-replay.json).

## Cache proposal: availability before larger limits

Earlier same-process counters at 22:59 UTC recorded 58,034 provider-reported cache hits and 122,615,808 avoided prefill tokens. The recent Datadog hour shows Gemma's accepted lookup receipts at 993 hits versus 111,729 absent-prefix misses. These different cohorts must not be combined into a single hit percentage.

The deployed allowlist still contains four artifacts: Gemma QAT and Qwen 3.5/3.6/3.8. Nemotron is not allowlisted. Provider GPT-OSS default cache support exists only in the newer source commit. Enabling either model needs exact artifact/contract qualification and a separately approved rollout.

`coordinator/registry/cache_receipts_v2_lookup.go` validates the dispatched identity, expected prompt/boundaries and receipt sequence before publishing a holder. `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDHybridCheckpointStore+Maintenance.swift` rotates the cache epoch for destructive changes; `SSDHybridCheckpointStore+Write.swift` rejects a queued donation if that epoch changed. Whole-root maintenance can therefore remove one entry and invalidate holder evidence and queued donations for that model. This mechanism is intentional evidence revocation; removing the barrier would weaken correctness.

Proposal: measure cache loss by model and lifecycle reason, distinguish unique useful prefixes from repeated donation attempts, and evaluate batching maintenance or explicit per-entry withdrawal with unchanged evidence guarantees. Investigate restore-budget refusals and write-rate limits separately. Do not turn unreported cache usage into misses, or increase SSD write rates solely because the blocked-attempt count is large.

## Model residency and the implemented correction

The provider already supports the user's requested behavior. A coordinator `load_model` for an advertised downloaded model can cause `ProviderLoop.evictUntilAvailable` to unload least-recently-used idle models. Active requests, local reservations, unloading models and retained MTP upgrade targets are protected. The feasibility check refuses an impossible load before evicting useful models. Downloaded files and the user's selected model catalog are preserved.

The warm-pool planner had a reproducible allocation defect before that path: multiple models took their first N candidates from the same fleet snapshot. After model A reserved the best machines, model B tried the same machines and accepted fewer loads without trying its remaining eligible candidates. Observe-only planning even assigned the same machine to both models.

The correction in `coordinator/registry/warm_pool_allocation.go` assigns each provider once per planning pass and replaces lost reservations from the remaining ranked shortlist. It preserves each model's allowance and the current per-tick/global-pending allowance, does not rescan the fleet, and visits each candidate at most once per model. Existing reservation and send-failure cleanup paths remain in use.

In the regression scenario, two models each need two loads and share four eligible cold machines. Before: A receives two loads and B receives zero. After: each receives two loads in the same tick. The observe-only plan now matches that exclusive allocation. This proves the defect and correction; production telemetry does not currently quantify how many historical load opportunities were lost this way.

Longer-term proposal: prioritize residency changes by measured demand deficit and displacement cost, retain a warm floor for models still receiving demand, and apply a dwell period before reversing a placement. Do not unload quiet models merely to maximize an aggregate utilization number.

## Validation and rollout gates

The regression test fails on the original controller in both active and observe-only modes and passes after the correction. The focused warm-pool suite, all coordinator packages (`go test ./... -p 4`), and the warm-pool race suite (`go test -race ./registry -run TestWarmPool -count=1`) pass. The change is source-validated and not deployed.

The allocation fix requires only a coordinator rollout and uses the existing provider protocol. Compare per-model planned/accepted loads, target deficits, pending-load duration, load failures, model churn and successful delivery under similar offered load. Keep the current bounded load limits. Revert the coordinator image if loading churn or serving outcomes regress; do not change trust policy, output limits, catalog choices or provider release as part of this narrow fix.
