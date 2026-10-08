# Cache-aware routing: activation, ramp and rollback

> Last updated: 2026-10-05

How to turn provider-confirmed prefix-cache routing on for the production
coordinator, widen its activation bounds one at a time, and turn it off again.
Written for an operator with production access; how the feature works is in
[`../architecture/cache-aware-routing.md`](../architecture/cache-aware-routing.md).

## When to use

- First production activation of `EIGENINFERENCE_CACHE_ROUTING_MODE=on`.
- Raising `EIGENINFERENCE_CACHE_ROUTING_PERCENT` or
  `EIGENINFERENCE_CACHE_ROUTING_MAX_PLAN_QPS` after a clean observation window.
- Adding a qualified model artifact to an existing routing cohort.
- Turning cache routing off — on its own, or as the first step of a coordinator
  binary rollback.

Use `EIGENINFERENCE_CACHE_ROUTING_ALLOWED_ARTIFACTS` to restrict network
participation to measured exact model/weight/template tuples before selecting
the request cohort. Unset preserves unrestricted existing eligibility; `[]`
declines all participation. This is an optional coordinator control, not a
provider capability override or a restriction on local HTTP caching
(`coordinator/registry/cache_artifact_allowlist.go`).

For the 0.9.0 rollout, configure this list explicitly with the validated tuples
for `qwen3.5-35b-a3b`, `qwen3.6-35b-a3b-vl-mtp-mxfp8` and
`EigenLabs/Qwen3.8-27B-4bit-mtp`. GPT-OSS and Gemma QAT use paged attention but
remain outside the initial SSD/cache-routing cohort. A successful paged-attention
test alone does not qualify a tuple for cache routing. See the
[five-model release decision](../design/release-090-paged-qwen-cache.md).
Leave the provider's `DARKBLOOM_PREFIX_CACHE` unset to use its
[model defaults](../architecture/prefix-cache.md#kv-layouts). Default SSD eligibility
for Gemma QAT, GPT-OSS or Bonsai 2 does not change the deployed routing allowlist.
Adding its exact model/weight/template tuple is a separate activation after validation.
An explicit affirmative value opts other supported models into SSD caching;
the coordinator allowlist restricts network participation but does not override
that local provider setting.

The mode remains global, and `PERCENT` samples a deterministic cohort keyed on
account + resolved model + provider-bound body (`cacheActivationCohort`,
`coordinator/internal/registry/cacheactivation/gate.go`). Within the admitted artifact subset,
the same request from the same account remains in or out of the cohort.

## Prerequisites

- Every `EIGENINFERENCE_CACHE_ROUTING_*` value is read **once at process
  start** (`ReadConfig`, `coordinator/registry/config.go`). A change is an
  env-file edit plus a coordinator restart: follow
  [`coordinator-deploy.md`](coordinator-deploy.md) → "Refresh the env file"
  and "Swap". Production env-file changes and restarts require explicit human
  approval for the specific operation ([`README.md`](README.md)); without it,
  prepare the commands and inspect read-only.
- The activation has already run on the dev coordinator
  ([`dev-environment.md`](dev-environment.md)) and shown: sidecar health,
  contract parity, provider capability identity, a proof-mismatch rate you
  accept, positive durable-hit evidence, stable correlation telemetry and
  healthy prompt artifacts. Production activation is a separate decision from
  shipping the code.
- A separately provisioned cache master key. `EIGENINFERENCE_CACHE_MASTER_KEY`
  must encode exactly 32 bytes as base64url, base64 or hex
  (`decodeCacheMasterKey`, `coordinator/registry/cache_route_keys.go`); with
  mode `on` and a missing or malformed key the coordinator refuses to start
  (`CacheRoutingConfig.Check`, `coordinator/registry/config.go`). Its entry,
  with the other cache-routing variables, ranges and defaults, is in
  [configuration.md → Routing, admission and TTFT](../reference/configuration.md#routing-admission-and-ttft).
  The key is operator-owned: the deploy's env refresh never writes or changes
  it ([`coordinator-deploy.md` → Environment file](coordinator-deploy.md#environment-file)).
- The prompt-contract sidecar is enabled and ready
  ([`EIGENINFERENCE_PROMPT_SIDECAR_ENABLED`](../reference/configuration.md#prompt-sidecar-and-media-fetch);
  `curl -fsS localhost:8080/v1/cache/status | jq -e .sidecar.ready`). Without
  it every request gets a non-participating plan and routing `on` changes
  nothing. This aggregate means the runtime has some usable tokenizer
  membership, not complete catalog readiness or current Go participation for
  every model. Verify the intended model's artifact and current-generation
  preload acknowledgement as described in
  [per-contract readiness](../architecture/prompt-contract-sidecar.md#process-and-lifecycle);
  `.preload.ready` and `.preload.contract_count` are subset diagnostics, not
  proof of a particular contract or a native KV hit.
- Datadog open on the `exact_cache.*` gauges
  (`EmitExactCacheDDGauges`, `coordinator/api/inference/exact_cache_metrics.go`) and the
  `routing.cache_selection_terminal`, `routing.cache_selection_precision` and
  `routing.cache_selection_discount_ms` series (`coordinator/api/provider/`).

## Steps

1. **Record the starting state.** Routing starts `off` — the shipped default
   ([configuration.md](../reference/configuration.md#routing-admission-and-ttft))
   and what `deploy/gcp/prod/release-env-defaults` seeds on a host that has no
   value yet.

   ```bash
   curl -fsS localhost:8080/v1/cache/status | jq -S \
     '{routing_mode, artifact_allowlist, activation, sidecar: {enabled: .sidecar.enabled, ready: .sidecar.ready, restarts: .sidecar.restarts}, providers, holders, attempts}' \
     | tee /tmp/darkbloom-cache-rollout.before.json
   jq -e '.routing_mode == "off" and .sidecar.ready and .providers.v2 > 0' /tmp/darkbloom-cache-rollout.before.json
   ```

   Confirm `artifact_allowlist.configured` and `artifact_allowlist.count` match
   the intended restriction. `configured: true, count: 0` deliberately denies
   participation; the status never exposes artifact identities. These values
   also have aggregate gauges in the [API contract](../reference/api-contracts.md#exact-cache-status).

   For the initial 0.9.0 cohort, require `configured: true, count: 3` and inspect
   the proposed configuration to verify all three exact Qwen tuples. A count
   alone cannot establish membership or successful model validation.

   `providers.v2` is the number of connected providers advertising the
   protocol-v2 capability (`PrefixCacheProtocolStatus`,
   `coordinator/registry/cache_status.go`); with none, activation can only
   produce cold plans.

2. **Install the master key** (skip if the env file already has one). The key
   must not appear in shell history or logs; write it straight into the
   root-only env file. `refresh-env.sh` rejects duplicate keys, so append only
   when the key is absent.

   ```bash
   sudo grep -c '^EIGENINFERENCE_CACHE_MASTER_KEY=' /etc/d-inference/env    # must print 0 before appending
   sudo sh -c 'umask 077; printf "EIGENINFERENCE_CACHE_MASTER_KEY=%s\n" "$(openssl rand -hex 32)" >> /etc/d-inference/env'
   ```

   `openssl rand -hex 32` yields 64 hex characters = 32 bytes, one of the
   encodings `decodeCacheMasterKey` accepts.

3. **Set the artifact subset and first-activation bounds.** For a restricted
   rollout, set `EIGENINFERENCE_CACHE_ROUTING_ALLOWED_ARTIFACTS` to a compact JSON
   array of objects with `model_id`, `model_aggregate_sha256` and
   `prompt_contract_id`. Take identities from the registered artifact manifest
   and its completed model validation; use resolved IDs and exact hashes, not
   family names or moving revision aliases. The [configuration reference](../reference/configuration.md#routing-admission-and-ttft)
   specifies the schema and startup limits. The release defaults do not populate
   this optional list. Setting it requires the same specific-operation approval
   as the other production env changes; removing it restores unrestricted
   eligibility, while `[]` keeps all network cache participation disabled.

   The first production activation uses
   `EIGENINFERENCE_CACHE_ROUTING_PERCENT=1` and
   `EIGENINFERENCE_CACHE_ROUTING_MAX_PLAN_QPS=1` — the values
   `deploy/gcp/prod/release-env-defaults` ships for those two bounds; their
   accepted ranges and code defaults are in
   [configuration.md](../reference/configuration.md#routing-admission-and-ttft) —
   with `EIGENINFERENCE_CACHE_ROUTING_MODE=on`. Both are caps inside `on`: the
   percentage is a deterministic per-request cohort over account, resolved
   model and provider-bound body, the QPS cap bounds sidecar planning; neither
   rejects or delays ordinary inference (`cacheActivationGate`,
   `coordinator/internal/registry/cacheactivation/gate.go`). Take a root-only backup, then
   edit the three lines in place:

   ```bash
   sudo cp -p /etc/d-inference/env "/etc/d-inference/env.bak.$(date -u +%Y%m%dT%H%M%SZ)"
   sudo sed -i -E \
     -e 's/^EIGENINFERENCE_CACHE_ROUTING_MODE=.*/EIGENINFERENCE_CACHE_ROUTING_MODE=on/' \
     -e 's/^EIGENINFERENCE_CACHE_ROUTING_PERCENT=.*/EIGENINFERENCE_CACHE_ROUTING_PERCENT=1/' \
     -e 's/^EIGENINFERENCE_CACHE_ROUTING_MAX_PLAN_QPS=.*/EIGENINFERENCE_CACHE_ROUTING_MAX_PLAN_QPS=1/' \
     /etc/d-inference/env
   sudo grep -E '^EIGENINFERENCE_CACHE_ROUTING_(MODE|PERCENT|MAX_PLAN_QPS)=' /etc/d-inference/env
   ```

   Later deploys preserve mode/cohort/QPS choices. The v0.9 env refresh retires
   only the exact historical limit pair `MAX_DISCOUNT_MS=1000` and
   `MAX_COST_FRACTION=0.35` together, replacing both values with blank optional
   limits. If either differs, both are preserved, including explicit zero.
   An intentionally retained exact stock pair cannot be distinguished from
   defaults; review the two `MIGRATE` lines from `--check` before approving
   refresh. A different numeric spelling such as `1000.0` is treated as an
   explicit customization and keeps the pair. Mode remains `off` unless
   separately activated (`deploy/gcp/prod/refresh-env.sh`;
   [`coordinator-deploy.md` → Environment file](coordinator-deploy.md#environment-file)).

4. **Restart the coordinator** per [`coordinator-deploy.md`](coordinator-deploy.md)
   → "Refresh the env file" and "Swap", with the currently approved image. On
   boot the process logs `provider-confirmed cache routing configured` with
   `mode`, `activation_percent`, `max_plan_qps`, `ttl`, `max_holders`,
   `max_discount_ms` and `max_cost_fraction` (`coordinator/app/registry.go`);
   `null` means no optional clipping beyond avoidable prefill work. A rejected configuration logs `cache routing configuration rejected` and
   exits before listening. With `EIGENINFERENCE_CACHE_ROUTING_PERSIST` on (the
   default), boot also logs `cache routing persistence restored` with parked
   holder and demand counts. Check `lifecycle.persistence.ready` and then
   `bound_holders` in `GET /v1/cache/status` as providers reconnect and apply
   matching capabilities. A failed boot restore is retried every 5 s; mutations
   stay pending and holder/demand writes wait for success. Routing still reads
   its in-memory index. See [persistence during restarts](#persistence-during-restarts)
   for reset precautions.

   ```bash
   sudo docker logs coordinator 2>&1 | grep -E 'cache routing configuration rejected|provider-confirmed cache routing configured'
   ```

5. **Widen one bound at a time.** After a clean observation window
   (Verification below shows hits and no sidecar distress), raise **either**
   `EIGENINFERENCE_CACHE_ROUTING_PERCENT` **or**
   `EIGENINFERENCE_CACHE_ROUTING_MAX_PLAN_QPS` — never both in one change —
   by repeating steps 3–4 with the new value, and observe again before the
   next step.

### Persistence during restarts

Inspect `GET /v1/cache/status` → `lifecycle.persistence` after a swap. Restored,
parked and bound counts describe routing evidence, not confirmed cache hits.
The final flush follows HTTP shutdown, provider-socket closure/join and the
periodic writer's join; a bounded shutdown can still lose pending work.

- If `flush_errors` grows, inspect store health. Failed writes remain pending;
  successful chunks acknowledge only their matching revisions. `rows_deleted`
  counts successfully submitted keys, including keys with no row, not rows
  actually removed. Exact [counter semantics](../reference/api-contracts.md#exact-cache-status)
  distinguish dropped work and stale-evidence rejection.
- If `overflow_resets` grows, the delete backlog exceeded its budget. The writer
  wakes to reset the durable copy; the counter records overflow, not completion.
  The process keeps a timestamp cutoff that rejects older or equal evidence
  even after reset. A durable in-progress marker makes an interrupted reset
  recoverable on boot, but a crash before that marker can still restore
  invalidated evidence. Verify recovery in the logs and `flush_errors`.
- Rotate `EIGENINFERENCE_CACHE_MASTER_KEY`, or deploy changed key-derivation
  versions, with an approved **non-overlapping restart**: stop the old container
  before the new one boots. `key_rotated: true` indicates the resulting rebuild.
  The writer is serialized only within one process. Another container can write
  stale rows during a generation or overflow reset; neither the marker nor the
  process-local cutoff coordinates multiple writers.
- Keep coordinator clocks aligned. Beyond the store's one-minute skew
  allowance, the lagging instance can prune the other's fresh rows.

The [persistence mechanism](../architecture/cache-aware-routing.md#persistence-across-restarts)
and its limits are unchanged at the store-schema, wire and configuration level
by the refactor; no new rollout knob is required.

### Add Bonsai to an existing routing cohort

Use this procedure when routing is already active for other artifacts. Preserve
their tuples and the current mode, percentage and QPS bounds; the initial
activation example above is not a reset procedure.

1. **Qualify the final signed provider and registered artifact.** Record the
   provider version/build hash, resolved model ID, aggregate weight hash and
   prompt-contract ID. Use `ternary-bonsai-2-27b` for the catalog model, with
   hashes from its current manifest and the sidecar's matching contract. Leave
   `DARKBLOOM_PREFIX_CACHE` unset and resident memory retention disabled to test
   the new default. Require the persistent Keychain-backed cache key; do not use
   `DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL` as restart evidence.
2. **Verify actual SSD restoration.** On the signed build, run a cold request
   long enough to donate at least one full checkpoint stripe, then repeat its
   prefix with a changed suffix. Record completed output, SSD writes/reads and
   saved prefill tokens. Restart the provider within the configured cache TTL
   and repeat to prove persistent-key reuse. Check another account misses and
   a damaged checkpoint in an isolated test cache falls back safely. Use the
   [SSD configuration](../reference/ssd-kv-cache.md) for TTL and staging bounds;
   use the production scheduler's prefill stripe from
   `EngineV2Factory.productionSchedulerConfig` in
   `provider-swift/Sources/ProviderCore/Inference/Engine/Factory/EngineV2Factory+Configuration.swift`.
   The existing `BonsaiEncryptedCheckpointLiveTests` fixture checks
   mechanics with real weights and a fixture key; it cannot replace these
   signed-build and account-isolation checks.
3. **Append the qualified tuple.** Add one object containing `model_id`,
   `model_aggregate_sha256` and `prompt_contract_id` to
   `EIGENINFERENCE_CACHE_ROUTING_ALLOWED_ARTIFACTS`, retaining every existing
   entry. Never replace the list with only Bonsai or unset it to enable Bonsai.
   If the list is currently unset, first inventory the participating artifacts
   before introducing a restriction. Follow the prerequisites and approved
   coordinator swap procedure above; the value is read only at startup.
4. **Verify hosted reuse.** Confirm ordinary Bonsai requests still complete,
   then correlate repeated same-account requests with provider SSD reads,
   saved prefill tokens and successful cache-selected completions. Holder
   counts or selection attempts alone do not prove reuse. Compare latency,
   cold fallback and errors with the recorded baseline using the verification
   signals below.
5. **Roll back the Bonsai routing addition if needed.** Restore the previous
   allowlist and restart through the approved procedure. This preserves other
   cache cohorts and ordinary Bonsai inference; it does not disable local SSD
   caching. For a provider-side cache problem, `DARKBLOOM_PREFIX_CACHE=0`
   disables caching for all its models. Apply it to the actual daemon
   environment; restarting an existing LaunchAgent does not import shell
   changes. See [provider environment propagation](../reference/configuration.md#where-values-are-set).

### Widen the plan gate and add Nemotron Lightning and Bonsai 2

Use this after the 2026-09 hit-rate fix set is deployed (bounded proof fence,
per-file eviction without epoch rotation, in-window holder preference,
demand-gated donation; see the
[analysis report](../reports/2026-09-26-prefix-cache-hit-rate-analysis.md)).
Production at that point ran `EIGENINFERENCE_CACHE_ROUTING_MAX_PLAN_QPS=40`
against roughly 50 evaluations per second, so 27.7% of requests were dispatched
with no cache scope, and the sidecar already reported overloads at
`EIGENINFERENCE_PROMPT_SIDECAR_MAX_CONCURRENCY=8`. Raise capacity before the
cap, one bound per restart, and observe between steps.

1. **Sidecar capacity first.** Double planner concurrency and give the child
   memory headroom (RSS was 781 MB of the 1,024 MB limit):

   ```bash
   sudo cp -p /etc/d-inference/env "/etc/d-inference/env.bak.$(date -u +%Y%m%dT%H%M%SZ)"
   sudo sed -i -E \
     -e 's/^EIGENINFERENCE_PROMPT_SIDECAR_MAX_CONCURRENCY=.*/EIGENINFERENCE_PROMPT_SIDECAR_MAX_CONCURRENCY=16/' \
     -e 's/^EIGENINFERENCE_PROMPT_SIDECAR_MEMORY_LIMIT_MIB=.*/EIGENINFERENCE_PROMPT_SIDECAR_MEMORY_LIMIT_MIB=2048/' \
     /etc/d-inference/env
   ```

   Restart per [`coordinator-deploy.md`](coordinator-deploy.md). Watch
   `.sidecar.overloads`, `.sidecar.planner.plans.at_capacity` and
   `.sidecar.rss_bytes` stay flat over an hour before the next step.

2. **Plan QPS.** Raise the cap above the observed evaluation rate:

   ```bash
   sudo sed -i -E 's/^EIGENINFERENCE_CACHE_ROUTING_MAX_PLAN_QPS=.*/EIGENINFERENCE_CACHE_ROUTING_MAX_PLAN_QPS=120/' /etc/d-inference/env
   ```

   Restart. `.activation.rate_limited` should stop growing and the
   `unreported` share of `routing.cache_model.usage` should fall by roughly a
   quarter. If `.sidecar.overloads` climbs instead, return to step 1 with a
   higher concurrency before retrying.

3. **Holder lifetime.** Providers keep a cache file for 30 minutes after its
   last use (`SSDPrefixCachePolicy.defaultTTLSeconds = 1800`, the limit signed
   off in `docs/threat-model.yaml` T-041) and no longer rotate their epoch on
   eviction. Keep the coordinator's holder TTL just inside that window so a
   holder never outlives its file:

   ```bash
   sudo sed -i -E 's/^EIGENINFERENCE_CACHE_ROUTING_TTL=.*/EIGENINFERENCE_CACHE_ROUTING_TTL=25m/' /etc/d-inference/env
   ```

   Restart. Do this only after the fleet's majority runs the provider release
   that carries the 30-minute TTL; against older providers (15 minutes) leave
   the holder TTL at `10m`. The holder and observed-demand indexes are sized
   for this window (`cacheRoutingMaxEntries`, `cacheDemandMaxEntries`,
   `coordinator/registry/cache_routing.go`). `.holders` should rise well above
   the previous ~1,000, `holder_removed.epoch_change` should fall toward zero
   as providers upgrade, `holder_removed.capacity_eviction` should stay flat,
   and `holder_removed.ttl` becomes the dominant removal reason, which is the
   healthy state.

4. **Append the two tuples.** Both were derived on 2026-09-26 from the active
   registry versions (`nvidia-nemotron-3.5-lightning` `2026-09-09-r1`,
   `ternary-bonsai-2-27b` `2026-09-17-r1`) with the coordinator's own
   `promptcontract.ContractID` over the manifest's tokenizer/template/config
   files; the same derivation reproduces the live `gpt-oss-20b` tuple exactly.
   Re-derive if either model's active version changes. Both literals below
   predate `darkbloom-request-normalization-v8` and Nemotron revision
   `2026-09-30-r1`, so neither matches a current build. Where the list already
   holds them, take the current tuples from the
   [stale-entry warning](#stale-entries-after-a-model-revision); otherwise
   re-derive them. Append, never replace:

   ```bash
   sudo python3 - <<'PY'
   import json, re
   p = "/etc/d-inference/env"
   src = open(p).read()
   m = re.search(r"^EIGENINFERENCE_CACHE_ROUTING_ALLOWED_ARTIFACTS=(.*)$", src, re.M)
   cur = json.loads(m.group(1))
   add = [
     {"model_id": "nvidia-nemotron-3.5-lightning",
      "model_aggregate_sha256": "be622ff6ae88533eb31ce984ddc95e5edc3bc52de1767536f2058151383d891a",
      "prompt_contract_id": "6a80df579e0d7c3b1db40d766831c1b0f75efd6864c6ee521d49557b9c7353b8"},
     {"model_id": "ternary-bonsai-2-27b",
      "model_aggregate_sha256": "ea1e901e4946c0ba9ad70c78517548808b353db6b3a13e87a8fa20468d81244c",
      "prompt_contract_id": "ce88a818490c1dcee6f5dac3b53f13ffe56e3f3ab91728626e9985b31a7d38e5"},
   ]
   have = {(t["model_id"], t["model_aggregate_sha256"], t["prompt_contract_id"]) for t in cur}
   cur += [t for t in add if (t["model_id"], t["model_aggregate_sha256"], t["prompt_contract_id"]) not in have]
   out = src[:m.start(1)] + json.dumps(cur, separators=(",", ":")) + src[m.end(1):]
   open(p, "w").write(out)
   print(len(cur), "tuples")
   PY
   sudo grep -c '"model_id"' /etc/d-inference/env
   ```

   Restart and confirm `artifact_allowlist.count` is 7. Bonsai's median prompt
   is about 126 tokens, so expect few Bonsai hits until the checkpoint floor
   drops; Nemotron has 83% of prompts above 1,024 tokens.

## Verification

```bash
curl -fsS localhost:8080/v1/cache/status | jq -e \
  '.routing_mode == "on" and .activation.percent == 1 and .activation.max_plan_qps == 1 and .sidecar.ready'
```

Adjust the two numbers to the bounds you set. Then, over the observation
window (fields from `CacheRoutingActivationStatus`,
`coordinator/internal/registry/cacheactivation/gate.go`, and `CacheRoutingLifecycleStatus`,
`coordinator/registry/cache_routing.go`):

- `.activation.evaluated` climbs; `.activation.sampled_in` tracks the
  percentage share of it; `.activation.rate_limited` counts requests the QPS
  cap declined; `.activation.planned` grows while `.activation.plan_failed`
  stays flat.
- `.lifecycle.ssd_lookups`, `.lifecycle.ssd_donations` and then
  `.lifecycle.ssd_hits` become non-zero as sampled requests repeat — the
  cohort is deterministic, so a sampled cold miss donates and the same
  request later hits — and `.holders` rises above `0`.
- `.sidecar.restarts`, `.sidecar.timeouts` and `.sidecar.overloads` do not
  grow; `.prompt_artifacts.failed` stays `0`.
- `.artifact_allowlist.stale_models` is `0`. Any other value means a listed
  model is being served without cache routing; see
  [stale entries](#stale-entries-after-a-model-revision).
- Datadog: `exact_cache.routing_mode` reports `mode:on`;
  `exact_cache.activation.total` by `outcome` matches the counters above;
  `routing.cache_selection_terminal` carries `selected`, `lookup_outcome`,
  `cache_read`, `tier` and `result` tags with `cache_read` successes
  appearing; `routing.cache_selection_precision` is non-zero.
- Ordinary traffic is not harmed: the activation gate only declines cache
  participation, so the `429` rate does not move with the flip.
- Latency has not regressed: compare p50/p95 first-content latency per model
  before and after the flip with the recipes in
  [`profiler-queries.md`](profiler-queries.md). `request_profiles.cache_discount_ms`
  (> 0 when the chosen provider received a cache discount) is the only cache
  signal in the profiles, so split by it or compare time windows rather than
  cohorts. A regression is the rollback trigger below.

Compare with the snapshot from step 1 when in doubt:

```bash
diff <(jq -S . /tmp/darkbloom-cache-rollout.before.json) <(curl -fsS localhost:8080/v1/cache/status | jq -S \
  '{routing_mode, activation, sidecar: {enabled: .sidecar.enabled, ready: .sidecar.ready, restarts: .sidecar.restarts}, providers, holders, attempts}')
```

### Stale entries after a model revision

A tuple names one artifact. Publishing new weights or a new template under the
same model ID changes `model_aggregate_sha256`, and a new template also changes
`prompt_contract_id`, so the existing entry stops matching
(`coordinator/internal/registry/cachepolicy/artifacts.go`, `ArtifactAllowlist.Allows`).
Every request for that model is then planned as `ineligible`, its providers
receive no cache scope, and its cache hits fall to zero while other models keep
theirs. Inference itself is unaffected. A coordinator release that changes a
prompt-contract version does the same to every listed model at once.

The coordinator reports the gap instead of leaving it to be inferred:

- `.artifact_allowlist.stale_models` in `GET /v1/cache/status` counts catalog
  models the list names only under a superseded artifact, with gauges
  `exact_cache_artifact_allowlist_stale_models` and
  `exact_cache.artifact_allowlist.stale_models`. Alert when it is above `0`.
- The coordinator log carries one warning per stale model, naming its live
  `model_id`, `model_aggregate_sha256` and `prompt_contract_id`
  (`coordinator/api/inference/exact_cache_allowlist_staleness.go`,
  `warnNewlyMissingAllowlistEntries`). That is the tuple to append.

```bash
sudo docker logs coordinator 2>&1 | grep 'cache routing allowlist names this model under another artifact'
```

Qualify the new artifact as in step 1 of
[the Bonsai procedure](#add-bonsai-to-an-existing-routing-cohort), append the
logged tuple without removing the previous one, and restart through the
approved procedure. Keep the previous tuple while providers converge or a
rollback is possible. `stale_models` returns to `0` after the restart. A model
that was never listed is excluded on purpose and is not counted.

### Per-model rollout evidence

After deploying model metrics, query the same time window for each series:

```text
sum:d_inference.routing.cache_model.usage{env:production,outcome:hit} by {model}.as_count()
sum:d_inference.routing.cache_model.usage{env:production,outcome:miss_absent} by {model}.as_count()
sum:d_inference.routing.cache_model.usage{env:production,outcome:miss_corrupt} by {model}.as_count()
sum:d_inference.routing.cache_model.prefill_tokens_saved{env:production} by {model}.as_count()
sum:d_inference.routing.cache_model.lookup{env:production,outcome:hit} by {model}.as_count()
sum:d_inference.routing.cache_model.selection{env:production,selected:true,result:hit} by {model}.as_count()
```

Reported hit rate is `hits / (hits + miss_absent + miss_corrupt)`. Track
`invalid`, `unreported` and `skipped_*` usage separately; their presence is not
proof of a lookup miss. Compare accepted `lookup` and `selection` evidence
alongside reported reuse; do not add those populations together. Request success
and first-content latency still come from the existing request-outcome/profile
metrics. `selection.result=hit` does not itself prove a successful response.

Token-weighted prompt coverage is `100 * usage_prefill_tokens_saved /
usage_prompt_tokens` with identical model, outcome and tier filters over the
same window. Add `outcome:hit` for the percentage of hit prompts that avoided
prefill; include miss/skipped outcomes for all valid reported cache attempts.
`lookup_prefill_tokens_saved / lookup_prompt_tokens` instead describes accepted
proofs, with the coordinator plan as denominator. `selection_prefill_tokens_saved / selection_prompt_tokens`, filtered by `selected:true,result:hit`, describes
cache-selected reported-hit terminals. Never divide across these populations.
Zero/missing denominators mean unavailable coverage, not zero benefit.

Inspect `receipt` by model/type/reason to locate evidence rejection. For
`prompt_anchor_mismatch`, `prompt_mismatch.detail` distinguishes
`same_length_hash`, `provider_shorter` and `provider_longer`; these categorical
diagnostics contain no hashes or token sequences. They narrow investigation,
but do not identify a production request shape or explain every mismatch.

Mean stage milliseconds is `provider_stage_us / provider_stage_samples / 1000`
with identical model/outcome/tier filters. Mean observed first-content milliseconds
is `ttft_us / ttft_samples / 1000`, grouped by model and terminal cache outcome.
Estimated savings in seconds is
`estimated_ttft_saved_us / 1000000`; filter `selected:true,result:hit` for the
cache-selected reported-hit subset. This remains a scheduler estimate, not a
measured uncached comparison. Admin metrics expose the same counters and timing
histograms. See the [metric inventory](../reference/telemetry-inventory.md#cache-results-by-model-internal).
These breakdowns start at deployment and cannot reconstruct prior model counts.

## Rollback

Rollback always sets routing to `off` **before** any binary rollback.

1. Set `EIGENINFERENCE_CACHE_ROUTING_MODE=off` in the env file and restart the
   coordinator (steps 3–4 above, changing only the mode). `off` needs no
   master key (`CacheRoutingConfig.Check`), and `ConfigureCacheRouting`
   installs a fresh, empty holder/attempt tracker on every application, so the
   restart clears all in-memory cache evidence
   (`coordinator/registry/cache_routing.go`). Leave
   `EIGENINFERENCE_CACHE_MASTER_KEY` and the other `EIGENINFERENCE_CACHE_ROUTING_*`
   values in place; re-activation is then a one-line change.

   ```bash
   sudo sed -i -E 's/^EIGENINFERENCE_CACHE_ROUTING_MODE=.*/EIGENINFERENCE_CACHE_ROUTING_MODE=off/' /etc/d-inference/env
   ```

2. Verify the coordinator is cold again:

   ```bash
   curl -fsS localhost:8080/v1/cache/status | jq -e '.routing_mode == "off" and .holders == 0 and .attempts == 0'
   ```

3. Only then, if the binary itself must go back, follow
   [`coordinator-deploy.md` → Rollback](coordinator-deploy.md#rollback).

## Related

- [`../architecture/cache-aware-routing.md`](../architecture/cache-aware-routing.md) — what the flags gate, the guarantee, invariants and failure modes.
- [`../reference/configuration.md`](../reference/configuration.md#routing-admission-and-ttft) — every `EIGENINFERENCE_CACHE_ROUTING_*` variable, `EIGENINFERENCE_CACHE_MASTER_KEY`, ranges and defaults.
- [`../reference/api-contracts.md`](../reference/api-contracts.md) — `GET /v1/cache/status`.
- [`coordinator-deploy.md`](coordinator-deploy.md) — env-file refresh, swap, rollback, and the digests that prove a deploy left these controls untouched.
- [`routing-v2-rollout.md`](routing-v2-rollout.md) — kill switches for the other routing flags.
- [`dev-environment.md`](dev-environment.md) — where to run the activation first.
