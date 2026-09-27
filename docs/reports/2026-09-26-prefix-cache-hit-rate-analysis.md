# Prefix cache hit rate: production analysis and levers

> Last updated: 2026-09-26 · commit `efc7b71f9`

As of 2026-09-26, exact prefix-cache routing is on in production at 100%
(container started 2026-09-23; the flip date is not recorded here), 1,196 of
1,415 loaded model slots advertise a ready SSD cache, and 90% of served traffic
runs provider 0.9.9. The measured result is a **1.4–5.2% hit
rate per model** and **2–7% of prompt tokens saved**. Roughly 85% of gpt-oss
and Gemma routing evaluations carry a prefix the coordinator saw within the
previous minute or so; almost none of them find cache evidence to route on. This
report records what production shows, ties each loss to the code that causes
it, and ranks the levers. It is an assessment; no production or code change is
recorded here.

## What is live

| Control | Value | Source |
|---|---|---|
| `EIGENINFERENCE_CACHE_ROUTING_MODE` | `on` | prod `/etc/d-inference/env`, container env |
| `EIGENINFERENCE_CACHE_ROUTING_PERCENT` / `_MAX_PLAN_QPS` | `100` / `40` | same |
| `EIGENINFERENCE_CACHE_ROUTING_TTL` / `_MAX_HOLDERS` | `10m` / `4` | same |
| `EIGENINFERENCE_CACHE_ROUTING_ALLOWED_ARTIFACTS` | 5 tuples: Qwen 3.8, qwen3.5-35b-a3b, qwen3.6-35b-a3b-vl-mtp-mxfp8, gemma-4-26b-qat-4bit, gpt-oss-20b | same |
| Prompt sidecar | enabled, ready, `MAX_CONCURRENCY=8`, `TIMEOUT_MS=1000`, `MEMORY_LIMIT_MIB=1024` | same |
| Coordinator image start | 2026-09-23 21:33 UTC | `docker inspect coordinator` |
| Provider default SSD cache | on for the five artifacts plus Nemotron Lightning and Bonsai 2 (`PrefixCachePolicy.isEnabled`) | `provider-swift/Sources/ProviderCore/Inference/PrefixCache/PrefixCachePolicy+Activation.swift` |
| Provider SSD TTL / write cap / disk budget | `defaultTTLSeconds = 900`, `defaultMaxWriteBytesPerDay = 150 * 1_000_000_000`, `max(1, volumeFree / 2)` | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCachePolicy.swift`, `PrefixCachePolicy.swift` |
| Provider version share (10% profile sample, winning attempts, 2 h) | 0.9.9 90.3%, 0.9.7 3.4%, 0.9.6 2.6%, 0.9.8 1.2%, older 2.5% | prod `request_profiles` |

Nemotron Lightning and Bonsai 2 are default-on at the provider but not in the
coordinator allowlist; `qwen3.5-9b` is neither default-on nor allowlisted and
resolves to the contiguous backend under `auto`. None of the three receives a
cache scope, so their providers run every network request with
`prefixCacheEnabled=false`.

## Outcome by model

Datadog `d_inference.routing.cache_model.*`, `env:production`, seven days ending
2026-09-27 00:30 UTC. `usage` counts completion terminals; `unreported` means
the provider sent no cache usage, which covers non-participating requests
(throttled, plan failed, no scope), providers with no cache-ready model and
error terminals.

| Model | Completions | Hit | Miss (absent) | Unreported | Hit rate | Prefill tokens saved | Token coverage |
|---|---:|---:|---:|---:|---:|---:|---:|
| gemma-4-26b-qat-4bit | 18.20M | 255,741 | 8,876,719 | 9,063,112 | 2.8% | 502M | 1.9% |
| gpt-oss-20b | 8.93M | 298,965 | 5,442,076 | 3,191,028 | 5.2% | 660M | 4.1% |
| qwen3.6-35b-a3b-vl-mtp-mxfp8 | 2.31M | 44,445 | 1,040,136 | 1,220,511 | 4.1% | 188M | 4.3% |
| qwen3.5-35b-a3b | 0.94M | 25,186 | 464,100 | 450,114 | 5.1% | 108M | 7.0% |
| EigenLabs/Qwen3.8-27B-4bit-mtp | 0.44M | 7,595 | 239,220 | 190,903 | 3.1% | 17M | 5.0% |
| nvidia-nemotron-3.5-lightning | 1.63M | 0 | 0 | 1,630,444 | not routed | 0 | 0 |
| qwen3.5-9b | 0.75M | 0 | 0 | 752,625 | not default-on, not routed | 0 | 0 |
| ternary-bonsai-2-27b | 0.17M | 0 | 0 | 166,641 | not routed | 0 | 0 |

Hit rate is `hit / (hit + miss_absent)`; token coverage is
`usage_prefill_tokens_saved / usage_prompt_tokens` over the same hit+miss
population. Across all 33.4M completions, 632k (1.9%) reused any prefix.

Per hit, providers restored 2,207 tokens (gpt-oss), 1,964 (Gemma), 4,227
(qwen3.6), 4,266 (qwen3.5-35b) and 2,292 (Qwen 3.8). Hit prompts averaged 6.7k,
4.3k, 6.5k, 10.7k and 3.7k tokens respectively, so a hit skips one third to two
thirds of its prompt. Mean SSD stage cost per hit was 90–210 ms. The scheduler's
own estimate of TTFT saved on a cache-selected hit was 1.2 s (Gemma) to 2.7 s
(Qwen 3.8); this is `estimated_ttft_saved_us / samples`, not a measured
counterfactual.

When the scheduler did select a holder, it was almost always right: for gpt-oss,
51,520 selected terminals reported a hit against 40 that reported a miss. The
problem is recall, not precision. Four out of five hits landed on providers the
scheduler had **not** selected for cache (gpt-oss 247,111 unselected hits vs
51,520 selected; Gemma 190,014 vs 65,695). The soft affinity tie-breaker is
the likely path for most of them `[INFERENCE]`: `opportunity_affinity` fired on
5.48M Gemma and 0.92M gpt-oss evaluations that had a repeated prefix but no
holder evidence, which is consistent with, not proof of, that attribution.

## The opportunity funnel

`d_inference.routing.cache_model.opportunity` by `reason`, same seven days.
The unit is a routing evaluation with a participating plan
(`CacheOpportunity.Evaluated`, `coordinator/registry/cache_opportunity.go`),
so counts exceed completions.

| Reason | gpt-oss-20b | gemma-4-26b-qat-4bit | qwen3.6 | qwen3.5-35b | Qwen 3.8 |
|---|---:|---:|---:|---:|---:|
| `repeat_without_holder` | 12,873,340 (68.6%) | 12,435,978 (74.5%) | 472,361 (34.3%) | 208,108 (32.0%) | 1,164,298 (70.9%) |
| `holder_not_selected` | 3,036,534 (16.2%) | 1,421,199 (8.5%) | 108,761 (7.9%) | 39,075 (6.0%) | 51,129 (3.1%) |
| `no_repeat_observed` | 1,971,764 (10.5%) | 1,986,282 (11.9%) | 748,784 (54.3%) | 389,915 (60.0%) | 403,421 (24.6%) |
| `holder_unavailable` | 699,844 (3.7%) | 723,100 (4.3%) | 20,837 (1.5%) | 4,368 (0.7%) | 20,146 (1.2%) |
| `selected` | 117,789 (0.6%) | 106,852 (0.6%) | 25,574 (1.9%) | 7,523 (1.2%) | 2,622 (0.2%) |
| `holder_no_positive_credit` | 79,617 (0.4%) | 18,589 (0.1%) | 2,360 (0.2%) | 569 (0.1%) | 401 (0.0%) |
| Total | 18,778,889 | 16,692,003 | 1,378,677 | 649,558 | 1,642,017 |

`no_repeat_observed` means no geometric block boundary (256, 512, 1,024, …
tokens, or the final boundary) of this prompt was planned by any request still
in the demand index (`cacheDemandTracker`, `coordinator/registry/cache_demand.go`).
The index is capped at `cacheRoutingMaxEntries = 10_000` entries under the
10-minute routing TTL; at roughly 35 planned requests per second and about
five keys per plan it turns over in about a minute, so "repeat" here means
repeated within the last minute or so, and the true repeat share over ten
minutes is higher still.
Everything else is repeated demand. For gpt-oss and Gemma, **only 10–12% of
evaluations are genuinely novel**; 85–90% repeat a prefix the coordinator has
already tokenized.

- `repeat_without_holder` (69–75%): a prefix repeated within the last minute
  or so, zero holders in the index.
  Mean repeated length 1,614 tokens (gpt-oss) and 1,474 (Gemma). This bucket
  mixes prefixes below the checkpoint floor with prefixes whose evidence was
  never created or was already removed (next two sections).
- `holder_not_selected` (16% / 8.5%): a live holder with positive credit lost
  to a cheaper cold provider. Mean repeated length 5,522 tokens (gpt-oss) and
  2,282 (Gemma), with 3.2–3.5 matching holders per evaluation. The 16.8B
  repeated gpt-oss tokens in this bucket are 25× the 660M tokens gpt-oss
  actually saved all week; that is an upper bound, since the holder's anchor
  can be shorter than the repeated prefix.

## Why holders disappear

`GET /v1/cache/status` on the prod coordinator, cumulative since the
2026-09-23 restart (72 h):

| Counter | Value |
|---|---:|
| `lifecycle.ssd_lookups` / `ssd_hits` / `ssd_misses` | 12,459,870 / 202,397 (1.6%) / 11,985,590 |
| `lifecycle.ssd_donations` | 1,323,054 |
| `lifecycle.holder_added` | 1,978,158 |
| `holder_removed.epoch_change` | 1,397,409 (70.7% of removals) |
| `holder_removed.proof_mismatch` | 194,349 (9.8%) |
| `holder_removed.ttl` | 178,002 (9.0%) |
| `holder_removed.capacity_eviction` | 99,124 (5.0%) |
| `holder_removed.capability_change` / `disconnect` / `miss_invalidation` | 82,978 / 19,745 / 5,732 |
| `holders` (now) / 7-day mean gauge | 819 / 1,318 |

Seven in ten holders die because the provider rotated its cache epoch, and the
fleet holds ~800–1,300 pieces of evidence at any moment across 707 v2
providers. The epoch rotates far more often than the design text ("SSD capacity
eviction rotates its durable epoch") suggests:

- `SSDHybridCheckpointStore.evictOldestEntry()`
  (`provider-swift/Sources/ProviderCore/KVCacheSSD/SSDHybridCheckpointStore+Maintenance.swift`)
  wraps **each single evicted file** in `performIndexedDestructiveChange`, which
  calls `SSDCacheEpochStore.performOwnedDestructiveChange` and persists a fresh
  epoch before the body runs. `SSDDiskBudget.enforce`
  (`SSDBlockIndex.swift`) calls it once per victim until the box is under
  budget.
- `SSDWholeRootMaintainer` (`intervalSeconds = 60`) removes **TTL-expired**
  files through `SSDDiskBudget.shared.performActiveDestructiveChange(root:)`,
  which is the same epoch-rotating path
  (`performExternalDestructiveChange` → `performIndexedDestructiveChange`).
  With `defaultTTLSeconds = 900` and steady traffic, every sweep on a busy
  provider expires something, so the epoch would rotate about once a minute
  per model root `[INFERENCE]`: this follows from the code path and the TTL;
  no per-provider rotation rate was measured.
- The coordinator invalidates every holder for that provider/model on any
  epoch change (`holder_removed.epoch_change`), and rejects in-flight donations
  (`donation_outcomes.cache_epoch_changed` = 488,611).

The provider still holds and serves the surviving files; only the coordinator
forgets them. That asymmetry is why hits land four-to-one on unselected
providers, and why `EIGENINFERENCE_CACHE_ROUTING_TTL=10m` is not the binding
lifetime.

## Why donations are dropped

Provider-reported `donation_outcomes` in the same status snapshot:

| Outcome | Count | Share of attempts |
|---|---:|---:|
| `donated` | 2,474,003 | 45.5% |
| `write_priority_limited` | 2,158,664 | 39.7% |
| `cache_epoch_changed` | 488,611 | 9.0% |
| `write_rate_limited` | 274,211 | 5.0% |
| `disk_space_insufficient` | 32,842 | 0.6% |
| `already_durable` / `already_queued` / `write_queue_full` | 7,219 / 2,628 / 3,862 | 0.3% |

`write_priority_limited` is the novel-tag sub-budget of
`SSDWriteRateLimiter` (90% of `defaultMaxWriteBytesPerDay = 150 * 1_000_000_000`);
`write_rate_limited` is the total budget. A gpt-oss-20b complete checkpoint
measured 308,110,124 bytes for 6,144 tokens in the
[09-11 qualification](2026-09-11-gptoss-default-prefix-cache.md), about 50 KB
per token, so a median 3.3k-token gpt-oss prompt is a ~160 MB write and the
daily cap admits roughly 900 novel donations per provider per day. Other
models' per-token sizes are not measured here. Every completed prompt is
offered for donation whether or not anything will ever repeat it; the
`SSDCheckpointDemand` history (`limit: Int = 4096` tags within TTL) only
decides which sub-budget pays. The disk budget (`max(1, volumeFree / 2)`)
fills within hours at these sizes, which is what drives the per-entry
evictions above. `already_durable` at 7,219 has two readings that both matter for the fix:
repeated prefixes rarely survive on disk long enough to be found, and the same
prefix is novel on each of the ~700 providers that load spreading sends it to,
so provider-local history alone sees few repeats.

## Why prompts cannot reach a checkpoint

Checkpoints exist only at positions the engine actually computed as one
uniform chunk boundary:

- `SSDHybridCheckpointStore.acceptsCheckpoint` requires
  `position >= config.minEffectiveTokens` (`defaultMinEffectiveTokens = 1024`)
  and a multiple of `PrefixCachePolicy.blockSize` (256).
- `CBv2RecurrentCheckpointGeometry.record`
  (`libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/Prefix/HybridPrefixCacheContract.swift`)
  disarms the request (`isArmed = false`) unless every computed range is
  unpacked, exactly `cap` tokens, `cap`-aligned, and the same `cap` as the
  previous range.
- `cap` is `rec.plannedPrefillChunkSize`, set each step by
  `prefillChunkCap(for:)` in `SchedulerV2.swift`: the solo stripe when this
  request is the armed solo row (`defaultSoloPrefillStripeTokens = 2048`,
  `defaultDenseQwenSoloPrefillStripeTokens = 4096`), otherwise
  `config.prefillChunkSize`. A request that starts solo and gains decode
  company, or the reverse, changes `cap` mid-prompt and loses capture for the
  rest of the prompt.
- `prepareHistoricalCheckpoints` (`EngineLoopV2+HistoricalCheckpoint.swift`)
  also requires `range.upperBound < promptTokens.count`, no preemption and no
  media, and `CompleteCheckpointCapture` keeps only two checkpoints per request
  (`staged[requestID].count == 2`: the first and the latest).

Against the prompt-length distribution (prod `request_profiles`,
`estimated_prompt_tokens`, which is the coordinator's pre-dispatch estimate
rather than provider-reported usage; 10% sample, winning attempts, two hours
ending 2026-09-27 01:30 UTC). The Datadog `usage_prompt_tokens` means for the
week (Gemma miss ≈ 2.9k, gpt-oss miss ≈ 2.6k) are consistent with these
medians.

| Model | n | p25 | p50 | p75 | p90 | ≥1,024 | ≥2,048 | ≥4,096 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| gpt-oss-20b | 25,800 | 1,636 | 3,266 | 6,509 | 14,822 | 81.3% | 72.0% | 39.3% |
| gemma-4-26b-qat-4bit | 15,521 | 587 | 2,256 | 3,707 | 5,974 | 68.3% | 54.1% | 21.0% |
| EigenLabs/Qwen3.8-27B-4bit-mtp | 6,148 | 266 | 330 | 400 | 532 | 6.1% | 4.7% | 1.0% |
| qwen3.6-35b-a3b-vl-mtp-mxfp8 | 5,319 | 2,254 | 4,228 | 9,662 | 14,797 | 88.7% | 77.3% | 50.6% |
| qwen3.5-35b-a3b | 764 | 1,211 | 2,167 | 4,911 | 17,733 | 75.8% | 71.9% | 28.3% |
| ternary-bonsai-2-27b | 447 | 126 | 126 | 127 | 1,882 | 11.6% | 9.6% | 8.7% |
| Qwen3.5-9B | 398 | 689 | 1,631 | 4,466 | 8,688 | 69.1% | 42.5% | 32.9% |
| nvidia-nemotron-3.5-lightning | 153 | 1,507 | 1,717 | 5,911 | 18,616 | 83.0% | 44.4% | 30.1% |

A solo-prefilled Gemma prompt needs more than 2,048 tokens to leave any
checkpoint; 46% of Gemma prompts never can. Qwen 3.8 needs more than 4,096
under its dense stripe (1% of its prompts) or a uniform 1,024 under company;
its 70.9% `repeat_without_holder` is almost entirely structural. The two
retained checkpoints per donor also explain why a hit restores ~2k tokens of a
4–7k prompt: the "latest" checkpoint is often far below the prompt's end once
capture disarmed.

## Participation gate and sidecar

`activation` in the same status snapshot (72 h): `evaluated` 13,130,831,
`rate_limited` 3,640,793 (**27.7%**), `admitted` 9,490,038, `planned`
8,745,786, `plan_empty` 515,603 (3.9%), `plan_failed` 228,641 (1.7%). Average
demand is ~50 evaluations/s against `MAX_PLAN_QPS=40`, so more than a quarter
of requests are dispatched with no cache scope, cannot hit, cannot donate and
report `unreported`. The sidecar is not idle either: `overloads` 205,605,
planner `at_capacity` 106,312, `timeouts` 20,219, RSS 781 MB of a 1,024 MB
limit, plan latency p50 ≈ 10 ms and p90 ≈ 50 ms with `MAX_CONCURRENCY=8`.
Raising the QPS cap alone would move throttles into overloads.

Protocol counts: `providers.v2` 707, `v1` 440. A provider reports protocol 1
when none of its loaded models has a ready SSD or memory cache, or it has no
runtime identity (`prefixCacheV2Advertisement`,
`provider-swift/Sources/ProviderCore/Coordinator/CoordinatorClientState.swift`),
not because it runs an old binary. The status exposes only slot-level reasons,
not the provider-level mapping: `config_disabled` 110 slots,
`cache_init_failed` 96, `unsupported_layout` 11, `unsupported_backend` 2, and
slots whose model is outside the default-on list.

## Proof fencing amplification

Seven-day receipt counters: `lookup_v2 accepted` 29,618,512,
`lookup_v2 capability_fenced` 6,493,519 (**18% of lookups**),
`ready_v2 capability_fenced` 420,837, `prompt_anchor_mismatch` 179,691.
`cacheRoutingTracker.capabilityRejected` (`coordinator/registry/cache_receipts_v2.go`)
lifts a fence only when the advertised capability changes; there is no time or
count bound, and `disablePrefixCacheV2Model` also drops every holder for that
provider/model. One mismatch therefore discards ~36 later proofs on average.
`prompt_mismatch.detail` is dominated by `same_length_hash` (gpt-oss 68,089,
Gemma 44,410, Qwens 36,279) with `provider_longer` on gpt-oss at 17,693: same
token count, different chain, which points at a tokenization or template
divergence between the sidecar and the provider on a specific prompt shape.
This report does not identify that shape.

These fence numbers have to be reconciled with the rotation finding above. A
fence lifts as soon as the capability changes, and the epoch is the field that
changes, so if epochs rotated every minute on the affected providers, fences
would be short and could not cover 18% of lookups. Both observations hold
together only if rotation is rarer on the fenced providers than the code path
suggests, or if mismatches recur promptly on specific provider/model pairs
after each rotation `[INFERENCE]`. Either way the mismatch is systematic, not
noise, and lever 1 below removes the only thing that currently lifts fences:
without a bounded fence, stopping rotation would turn every mismatch into a
permanent quarantine.

## Scheduler credit versus load spreading

`cacheServiceCost` (`coordinator/registry/cache_service_cost.go`) credits at
most the request's prefill component, scaled by an evidence weight that decays
linearly to zero over the holder TTL, minus the measured stage cost. Queue,
pending, backlog and health penalties are untouched, and a pool with any cache
adjustment collapses the near-tie window (`nearTieCostWindowMs = 3_000`) to
zero (`selectRoutingCandidateWithAffinity`,
`coordinator/registry/candidate_selection.go`). A holder that is still finishing
the donor request, or has anything queued, loses to an idle cold peer whenever
those penalties exceed one to two seconds of credited prefill `[INFERENCE]`:
this follows from the cost decomposition; no sample of losing decisions was
pulled. `inference_routes` carries `pending_ms`, `backlog_ms`, `queue_ms` and
`cost_ms` per attempt and can verify it, bounded by `created_at`. That is the
`holder_not_selected` bucket. `holder_no_positive_credit` is small (0.1–0.4%),
so evidence-age decay is not the main loss.

## Root causes, ranked by lost hits

1. **Coordinator amnesia from per-file epoch rotation** (provider). Every TTL
   expiry sweep and every single budget eviction rotates the epoch, which
   wipes all coordinator evidence for that provider/model while the files stay
   readable. 70% of holder removals; the largest contributor to
   `repeat_without_holder`.
2. **Write economics that guarantee churn** (provider). Every completed prompt
   is written at ~50 KB/token, the 150 GB/day cap drops 45% of donations, and
   the disk budget forces continuous eviction, which feeds (1). Repeated
   prefixes are the minority (`already_durable` 7,219) of what gets written.
3. **Checkpoint geometry** (engine). A 1,024-token floor, a 2,048/4,096 solo
   stripe, uniform-chunk disarm under batching, and two retained checkpoints
   per donor exclude about half of Gemma prompts, nearly all Qwen 3.8 and
   Bonsai prompts, and cap the tokens a hit can save.
4. **Credit that cannot beat load spreading** (coordinator). With ~700
   providers and low utilization there is nearly always an idle cold peer;
   16% of gpt-oss and 8.5% of Gemma evaluations had a valid holder and routed
   elsewhere, although selected holders hit 99.9% of the time.
5. **Participation caps** (config). `MAX_PLAN_QPS=40` throttles 27.7% of
   requests; Nemotron Lightning and Bonsai 2 (1.8M completions/week) are not in
   the allowlist; `qwen3.5-9b` is not cache-eligible.
6. **Fence amplification** (coordinator). 180k mismatches discard 6.9M
   receipts, and only epoch rotation lifts a fence today.
7. **Short lifetimes** (config). A 10-minute coordinator TTL and a 15-minute
   provider TTL bound multi-turn reuse even after (1) and (2) are fixed.

## Levers, in recommended order

Each entry names the layer and the counter that should move.

1. **Stop rotating the epoch on single-file eviction and TTL expiry, and
   bound the fence in the same change** (provider + coordinator, both small).
   Reserve `performOwnedDestructiveChange` for whole-root wipes and
   corruption; let a removed file surface as an ordinary coordinator miss
   (`miss_invalidation` already exists), or add a targeted per-anchor
   invalidation receipt. This reverses the invalidation mechanism that
   [`cache-aware-routing.md`](../architecture/cache-aware-routing.md) names
   ("SSD capacity eviction rotates its durable epoch"); it is safe under the
   same page's guarantee that routing is an optimization and never a
   dependency, because a stale holder costs one cold serve on that provider
   followed by `miss_invalidation`. The co-requisite on the coordinator: lift
   `rejectedV2` after a short interval or a fixed number of rejected receipts,
   and drop only the holders whose proof mismatched, since rotation is
   currently the only event that clears a fence. Watch
   `holder_removed.epoch_change` fall toward zero, `holders` rise by two
   orders of magnitude, and `receipt.capability_fenced` stay bounded.
2. **Donate on evidence of demand, not on every completion** (provider, with
   an optional coordinator hint). The coordinator already computes
   `RepeatedPrefixTokens` before dispatch; forwarding a one-bit "seen before"
   hint in the sealed request, or using the provider's own
   `SSDCheckpointDemand` history as an admission gate, cuts novel writes by an
   order of magnitude, ends `write_priority_limited`, and stops the budget
   churn that feeds (1). Then raise `defaultTTLSeconds` from 900 toward an
   hour.
3. **Widen the plan gate with the sidecar** (config, two coordinator restarts,
   one bound at a time per
   [`cache-routing-rollout.md`](../operations/cache-routing-rollout.md)):
   `EIGENINFERENCE_PROMPT_SIDECAR_MAX_CONCURRENCY` 8 → 16 and more
   `MEMORY_LIMIT_MIB` first, then `EIGENINFERENCE_CACHE_ROUTING_MAX_PLAN_QPS`
   40 → 120. Expect `activation.rate_limited` to approach zero and
   `unreported` to fall by roughly a quarter.
4. **Add Nemotron Lightning and Bonsai 2 tuples to the allowlist** (config,
   per the rollout runbook's Bonsai procedure). Nemotron has 83% of prompts
   above 1,024 tokens; Bonsai's median prompt is 126 tokens, so expect little
   from it until (6).
5. **Make a proven holder win when it is close** (coordinator). Options, in
   rising order of change: credit the stage-adjusted saving against pending
   and backlog terms as well as prefill; add a bounded fixed bonus per fresh
   proof; or prefer the freshest holder inside a cost window (for example
   within the current 3 s near-tie window) instead of collapsing the window to
   zero. Precision is already 99.9%, so the risk is bounded. Watch
   `holder_not_selected` convert to `selected`.
6. **Lower and densify checkpoints** (engine). For historical-attention models
   (gpt-oss, Gemma QAT) any 256-token boundary is a valid checkpoint; capture
   at each 1,024 boundary regardless of chunk size, allow `cap` to change
   between ranges, and retain more than two checkpoints per donor (disk
   permitting after (2)). Recurrent Qwen keeps its uniform-chunk rule but can
   use a 1,024 solo stripe multiple. This is the only lever that reaches the
   sub-2k half of Gemma traffic, Qwen 3.8 and Bonsai.
7. **Find the mismatch** (coordinator + provider). Reproduce
   `same_length_hash` by diffing sidecar and provider tokenization on captured
   prompt shapes; the fence bound in (1) contains the damage but does not
   remove the cause.
8. **Fleet hygiene** (operations). 96 loaded model slots report
   `cache_init_failed` and 110 `config_disabled`; each is a provider that
   cannot hold evidence at all.

Expected ceiling `[INFERENCE]`: with 85–90% of gpt-oss and Gemma evaluations
repeating a recent prefix and 54–72% of their prompts above 2,048 tokens, a
recall-fixed system with today's geometry could plausibly reach a 30–50% hit
rate on those two models, against 3–5% now. Levers 1–3 are the cheapest and
address the largest buckets; lever 6 is what "more hits for all models" needs
for the short-prompt models. Lever 2's demand hint belongs on the coordinator
side if the fleet-wide repeat is what matters (the same prefix is novel on each
provider it is spread to), with provider-local history as the fallback.

## Windows and sources

- Coordinator status: `curl localhost:8080/v1/cache/status` on
  `darkbloom-coordinator` over IAP SSH, 2026-09-27 00:20 UTC; counters are
  cumulative since the 2026-09-23 21:33 UTC container start.
- Datadog: `GET /api/v1/query` with `env:production`, seven days ending
  2026-09-27 00:30 UTC, series `d_inference.routing.cache_model.{usage,
  usage_prompt_tokens, usage_prefill_tokens_saved, prefill_tokens_saved,
  lookup, selection, receipt, prompt_mismatch, donation, ttft_us,
  ttft_samples, provider_stage_us, provider_stage_samples, opportunity,
  opportunity_affinity, opportunity_repeated_prefix_tokens,
  opportunity_matching_holders, estimated_ttft_saved_us,
  estimated_ttft_saved_samples}`, `d_inference.exact_cache.{activation.total,
  holders, attempts}`, `d_inference.routing.cache_selection_terminal`.
- Prompt lengths and versions: read-only `psql` on the coordinator VM against
  `request_profiles` (`EIGENINFERENCE_PROFILE_SAMPLE_RATE` default 0.1),
  `created_at > now() - interval '2 hours'`, `winning`.
- Code: the paths cited inline, at commit `efc7b71f9`.

## Related

- [`../architecture/prefix-cache.md`](../architecture/prefix-cache.md) — KV
  layouts, checkpoint capture, SSD gates.
- [`../architecture/cache-aware-routing.md`](../architecture/cache-aware-routing.md)
  — proof, holder lifecycle, service cost.
- [`../operations/cache-routing-rollout.md`](../operations/cache-routing-rollout.md)
  — how to change the bounds in production.
- [`../reference/ssd-kv-cache.md`](../reference/ssd-kv-cache.md) — SSD format
  and knobs.
- [GPT-OSS 20B default SSD prefix-cache qualification](2026-09-11-gptoss-default-prefix-cache.md)
  — the 308 MB / 6,144-token checkpoint measurement and lab TTFT reductions.
