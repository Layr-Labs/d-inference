# Cache-aware routing: activation, ramp and rollback

> Last updated: 2026-10-06

How to turn provider-confirmed prefix-cache routing on for the production
coordinator, widen its activation bounds one at a time, and turn it off again.
Written for an operator with production access; how the feature works is in
[`../architecture/cache-aware-routing.md`](../architecture/cache-aware-routing.md).

## When to use

- First production activation of `EIGENINFERENCE_CACHE_ROUTING_MODE=on`.
- Raising `EIGENINFERENCE_CACHE_ROUTING_PERCENT` or
  `EIGENINFERENCE_CACHE_ROUTING_MAX_PLAN_QPS` after a clean observation window.
- Adding a qualified model artifact to an existing routing cohort.
- Matching the holder TTL and the per-prefix holder limit to the fleet
  ([holder lifetime and holders per prefix](#holder-lifetime-and-holders-per-prefix)).
- Raising the first-sight minimum or turning first sight off
  ([first sight minimum](#first-sight-minimum)).
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
   `max_discount_ms`, `max_cost_fraction` and `first_sight_min_tokens`
   (`coordinator/app/registry.go`); `null` for either score limit means no
   optional clipping beyond avoidable prefill work. A rejected configuration logs `cache routing configuration rejected` and
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

3. **Holder lifetime and holders per prefix.** Follow
   [holder lifetime and holders per prefix](#holder-lifetime-and-holders-per-prefix):
   the holder TTL first, then the per-prefix limit, one restart each.

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

### Holder lifetime and holders per prefix

Run the coordinator with `EIGENINFERENCE_CACHE_ROUTING_TTL=30m` and
`EIGENINFERENCE_CACHE_ROUTING_MAX_HOLDERS=16`. Those are now the compiled
defaults
([configuration.md](../reference/configuration.md#routing-admission-and-ttft)),
and `deploy/gcp/prod/release-env-defaults` seeds the same two values on a host
that has neither key. `refresh-env.sh` never overwrites an existing value, so a
host whose env file pins `10m` and `4` keeps them until an operator edits the
file with the steps below. Check what a host runs with in the boot line
`provider-confirmed cache routing configured` (`ttl`, `max_holders`).

| Setting | Reason |
|---|---|
| `EIGENINFERENCE_CACHE_ROUTING_TTL=30m` | Providers keep a checkpoint for 30 minutes after its last use (`SSDPrefixCachePolicy.defaultTTLSeconds = 1800`, the limit signed off in `docs/threat-model.yaml` T-041) and no longer rotate their epoch on eviction. At a pinned `10m` the coordinator forgets a holder while the provider keeps the file for 20 more minutes, and a repeat in that interval is routed without cache credit. `30m` is the longest TTL the holder and observed-demand indexes are sized for (`cacheRoutingSizingTTL`, `coordinator/registry/cache_routing.go`); a longer value logs a startup warning. |
| `EIGENINFERENCE_CACHE_ROUTING_MAX_HOLDERS=16` | A production reading on 2026-10-05 showed 275,838 of 1,111,687 holder removals were `capacity_eviction` while the holder index held 25,196 of its 250,000 entries (`cacheRoutingMaxEntries`). With the index that far below its cap, the evictions came from the then-default limit of 4 holders per boundary dropping live holders of popular shared prefixes. |

Change one value per restart, under the approval and restart rules in
[Prerequisites](#prerequisites).

1. **Holder TTL.** Do this only after the fleet's majority runs the provider
   release that carries the 30-minute TTL; against older providers (15 minutes)
   leave the holder TTL at `10m`.

   ```bash
   sudo cp -p /etc/d-inference/env "/etc/d-inference/env.bak.$(date -u +%Y%m%dT%H%M%SZ)"
   sudo sed -i -E 's/^EIGENINFERENCE_CACHE_ROUTING_TTL=.*/EIGENINFERENCE_CACHE_ROUTING_TTL=30m/' /etc/d-inference/env
   sudo grep '^EIGENINFERENCE_CACHE_ROUTING_TTL=' /etc/d-inference/env
   ```

   Restart per [`coordinator-deploy.md`](coordinator-deploy.md). `.holders`
   should rise, `.lifecycle.holder_removed.epoch_change` should fall toward
   zero as providers upgrade, and `.lifecycle.holder_removed.ttl` should become
   the dominant removal reason. `.lifecycle.demand_cap_evictions` must stay
   flat: the observed-demand index keeps its entries for the same TTL and is
   sized for 60 plans per second at `30m` (`cacheDemandMaxEntries`), so a
   growing count means repeated prefixes are being reported as novel and the
   TTL goes back down. A holder now lapses with its file instead of before it.
   One that outlives its file by the receipt delay is removed by the next miss
   on that provider (`.lifecycle.holder_removed.miss_invalidation`), and that
   request runs cold.

2. **Holders per prefix.**

   ```bash
   sudo cp -p /etc/d-inference/env "/etc/d-inference/env.bak.$(date -u +%Y%m%dT%H%M%SZ)"
   sudo sed -i -E 's/^EIGENINFERENCE_CACHE_ROUTING_MAX_HOLDERS=.*/EIGENINFERENCE_CACHE_ROUTING_MAX_HOLDERS=16/' /etc/d-inference/env
   sudo grep '^EIGENINFERENCE_CACHE_ROUTING_MAX_HOLDERS=' /etc/d-inference/env
   ```

   Restart. `.lifecycle.holder_removed.capacity_eviction` should fall as a
   share of all removals. It need not reach zero: a prefix held by more than
   16 machines still evicts its oldest holder. `.holders` rises further and
   must stay well below 250,000. A plan's holder lookup visits at most
   `2 × B × H` records for `B` boundaries and `H` holders per bucket
   ([scheduler](../architecture/cache-aware-routing.md#scheduler)), four times
   the previous worst case, so compare p50/p95 first-content latency before and
   after as in [Verification](#verification).

Roll either value back by restoring its previous line and restarting.

### First sight minimum

[First sight](../architecture/cache-aware-routing.md#first-sight) lets the
second request of a new conversation hit instead of the third: the first
request is placed by the affinity key its follow-up will use, and its provider
is asked to keep the checkpoint that follow-up restores. The request travels
in its own frame count, `cache_first_sight_tokens`; the repeat count
`cache_repeated_prefix_tokens` stays 0 for it. It is on by default: with
`EIGENINFERENCE_CACHE_ROUTING_FIRST_SIGHT_MIN_TOKENS` unset the coordinator
uses a minimum of 1,024 tokens
([configuration.md](../reference/configuration.md#routing-admission-and-ttft)),
and `deploy/gcp/prod/release-env-defaults` does not seed the variable. It
applies once routing is `on` and the coordinator binary includes first sight
(`.activation.first_sight` is present in `GET /v1/cache/status`). Use this
procedure to raise the minimum or to turn first sight off with `0`.

First sight writes only on a provider release that understands
`cache_first_sight_tokens`. A provider that has the demand gate but not this
field ignores it: it reads a repeat count of 0 and settles the novel request's
checkpoints as `skipped_novel` (unless its own tag history has seen the tag),
as with first sight off, so first sight then only chooses the provider and
the third request of a conversation is again the first that can hit. The
coordinator still places such a request by its affinity key and still counts
it in `.activation.first_sight`, so that count alone does not show the fleet
is writing. A coordinator that sends `cache_first_sight_tokens` and providers
that understand it can be deployed in either order; a mixed fleet gets the
second-request hit only on upgraded providers.

One pair behaves differently. A coordinator build made before the count was
split sends the first-sight depth in `cache_repeated_prefix_tokens` and no
`cache_first_sight_tokens`. A provider that has this field then reads that
depth as an observed repeat and classes those writes `novel` (`repeated` when
its store saw the tag): they are admitted under the proven-write rules, as
they were before the split, the speculative limits below do not apply, and
`write_speculative_limited` is never reported for them. Every version pair is
in the
[`cache_first_sight_tokens` row](../reference/protocol-messages.md#inference_request).

How a provider treats a first-sight request. Its checkpoints are speculative:
nothing was observed twice, so they are last in line for the provider's SSD
write budget. A speculative write is admitted only when all four hold
([SSD write policy](../reference/ssd-kv-cache.md#size-and-eviction-rules)):

- it leaves both write buckets (the whole daily cap and the 90% novel share)
  within the headroom H of full. H is what the whole-cap bucket refills in one
  cache lifetime, `cap x TTL / 86,400`: 2.08% of the daily cap at the
  30-minute TTL, 15.6 GB at the 750 GB default. The novel share refills at 90%
  of that rate, so it needs `TTL / 0.9` to refill H, 33 minutes 20 seconds at
  the defaults, and a speculative write needs both buckets;
- no other checkpoint write is registered on that store (it is never queued
  behind a registered write);
- its complete stored file (the plaintext plus the file header, metadata and
  per-chunk framing) fits the free part of the cache's disk budget. Counted
  against the budget are the cache bytes already indexed, every other cache
  write in flight or queued in the provider process, the files of unloaded
  or closed models and leftover temp files; the budget is taken as it will
  be after the bytes land (the default, half of free disk, falls as bytes
  are written). The
  room is reserved for the write until its file is indexed or gone;
- no regular file is already at the checkpoint's path. A first-sight write
  does not replace a file; a proven write does.

Otherwise it is refused before a byte is written, charges nothing and is
counted as `donation_outcomes.write_speculative_limited`; the request
completes normally and its follow-up is offered as a proven repeat.

An admitted first-sight write can still end as `write_speculative_limited`.
A proven write is never refused room by this accounting and never waits for
room; the low-disk write stop still refuses any fresh write, as before. If it
needs the room a first-sight write was granted, or that room is gone when the
write rechecks it (the disk budget fell, or the maintenance pass found the
root over its limit), the first-sight write gives way: it stops at its next
chunk, or its finished file is not published, or its published file is
removed. Proven work that a store has accepted and not started, in the same
store or another, has no room reserved yet; it is counted when a first-sight
write is admitted, when it is about to publish and again when it is about to
be indexed, and the first-sight write gives way there if the room does not
hold both. A re-offer of a checkpoint that is already stored writes nothing
and is not counted. Whenever a first-sight write gives way, I/O happened
and the bytes were charged to the provider's daily write cap, with no refund,
and no checkpoint is kept. The provider counts these in the stat
`speculativeWritesYielded`, which
is process-local: it is not in the heartbeat, in `GET /v1/cache/status` or in
a metric, so the fleet reading cannot separate a write that gave way from one
declined before I/O. Proven
writes (a prefix the coordinator saw repeated, a tag the store saw before, or
a request that restored a checkpoint from that store) keep the budget rules
they had before first sight. `write_priority_limited`, `write_rate_limited`
and `write_queue_full` keep their meaning and are not reported for an offer
classed speculative; they still count the offers of a first-sight request
that are proven (a tag the store saw before, or a request that restored from
the store).

What speculation can cost proven writes
([limits 6, 7 and 10](../architecture/cache-aware-routing.md#first-sight)):

- **Write budget.** At any instant speculative writes hold at most H of each
  bucket, and a refused speculative write charges nothing. The limiter admits
  or refuses a write whole, so the cost is not "at most H bytes refused": it
  is bounded by the speculative bytes accepted (at most H) plus one proven
  file each time a bucket runs from full to empty, and it can recur in every
  such cycle.
- **Writer.** A proven write can settle `write_queue_full` where it would
  have queued without the speculative job: as the second proven arrival while
  a speculative file is being written, or as the first when it arrives after
  a speculative job was accepted and before the writer picked it up, which
  can happen while the writer is still finishing the previous job's
  completion callback. A proven offer for a checkpoint whose speculative write is
  already registered is absorbed by that write and settles `already_queued`;
  if the speculative job then refuses itself, gives way or fails, no
  checkpoint is kept.
- **Ready receipts.** A first-sight offer for a checkpoint that is already
  durable on the store, arriving while another write is registered, settles
  `write_speculative_limited` instead of `already_durable`, so the request's
  ready receipt does not name that checkpoint.
- **Volume.** H does not cap how much speculation writes in a day: a store
  with little proven traffic can spend its spare refill on first-sight files.
  A first-sight write that gave way spent write cap and left no checkpoint.
- **Disk.** While a first-sight write is in flight it does not cost an
  existing checkpoint its place: it was granted only free room, a proven
  write that needs that room takes it, and, within the limits stated in this
  paragraph and in limit 10, no eviction, by the maintenance
  pass (after a checkpoint write that stored its file or found it already
  stored, after a block-tier job and every 60 seconds) or after a
  checkpoint write,
  removes a committed entry on account of the in-flight write's bytes. Under
  the default budget those bytes also lower the free figure while they are
  on the volume, so both evictions take their limit without them. The pass
  reads the volume once it has started, and the eviction after a checkpoint
  write reads it again if a first-sight write was withdrawn since its
  reading; after three readings it evicts nothing and leaves the root to
  the next pass. Once the
  file is committed it is an ordinary entry: a proven write that arrives
  later and needs room evicts the least recently used entry whatever its
  class, which can be an older proven checkpoint while the newer first-sight
  file stays. While first-sight writes are being told to stop, the cache
  root can be over the disk budget it would have without their bytes by at
  most the sum of those bytes on disk; against the default budget read
  while they are on the volume, which is lower by half of them, that is up
  to one and a half times their bytes. The bytes are
  at most one file per loaded complete-checkpoint store, each at most
  the stage cap of plaintext (1 GiB unless
  `DARKBLOOM_PREFIX_CACHE_SSD_MAX_STAGE_MB` sets it) plus the file's framing.
  That lasts until each writer has finished the chunk it is on (one read of
  at most 4 MiB; with strict fsync on, also the file sync) and removed its
  file, with no time bound. The accounting is inside the provider process:
  it does not see another process writing under the same cache root, a temp
  file whose unlink failed, or a crash leftover before the next maintenance
  pass counts it. Free disk taken by other disk users between a first-sight
  write's commit check and the eviction that follows the commit can still
  evict an older entry; that span includes a whole maintenance pass, which
  walks the cache tree, and is not microseconds. What a proven write pays
  is a wait for the cache's disk-budget lock before its first byte and
  again at its index step (the file is published but not yet indexed while
  it waits); a block-tier write pays the same for each block. An eviction
  loop, a whole-root retirement or a reconcile in another store can hold
  that lock. The
  remaining limits (a budget reading that is out of date, an unowned-bytes
  figure that is too high or too low, the free figure) are in limit 10.

No measurement of this policy exists yet, including of how often a
first-sight write gives way.

Operational couplings: a shorter cache TTL shrinks the headroom in proportion;
a write cap of `0` (unlimited) removes the budget condition and leaves the
idle-writer, disk and path conditions. The buckets are per store and start full, so
a provider restart or store rebuild forgets pressure and grants a fresh
headroom. The disk budget is half of the volume's free bytes unless
`DARKBLOOM_PREFIX_CACHE_DISK_GB` sets it, or 20 GiB when the free bytes
cannot be measured
([SSD environment variables](../reference/ssd-kv-cache.md#environment-variables)):
under the default a first-sight write must fit the budget its own bytes
leave, and under an override or that fallback the budget does not move as
bytes land. The
default relies on the volume's free figure falling by the bytes written as
they are written. That was measured after a write, not during one, on one
machine, on its internal volume and one external volume, and on no other
([SSD write policy](../reference/ssd-kv-cache.md#size-and-eviction-rules),
limit 7); on a volume where the figure lags, a first-sight write can be
admitted against a budget that is too high and a later pass can evict. The
disk reservations live in the provider process and are gone at restart; the
files of models that are not loaded and leftover temp files are counted again
by the maintenance pass that runs when a complete-checkpoint store is built
or when the 60-second task first starts. Until such a pass has seen the whole
cache root, and again after a pass that could not list a directory or read a
file's attributes or header, after a start-up scan that failed, or after a
cache file was found missing or left behind by a failed unlink, the provider
declines every first-sight write under that root; `write_speculative_limited`
then grows with no write or disk pressure, the provider's log (category
`ssd_disk_budget`) says the occupancy of the cache root is unknown and why,
and the next whole pass (at most 60 seconds later) restores first sight
unless the fault persists. A directory or cache file that stays unreadable
keeps first sight off for every model under that cache root until it is
repaired or removed.

Small caps. Under a write cap other than `0`, a speculative write larger than
H is never admitted, whatever the buckets hold. On a store whose daily write
cap (`DARKBLOOM_PREFIX_CACHE_SSD_MAX_WRITE_GB_PER_DAY`) is below
`checkpoint size x 86,400 / TTL`, which is 48 times the size of one
first-sight checkpoint at the 30-minute TTL, H is smaller than that file: no
first-sight write of that size is ever admitted, each such offer is counted
as `write_speculative_limited`, and first sight only chooses the provider.
Example: a gemma-4-26b-qat-4bit checkpoint at 3,072 tokens is about 0.27 GB
(209.7 MB of fixed state plus 20.97 MB per 1,024 tokens,
[sizes per model](../architecture/prefix-cache.md#streamed-complete-checkpoints)),
so it needs a cap of about 13 GB/day. Checkpoint size grows with depth, so one
cap can admit a model's shallow first-sight checkpoints and never its deep
ones.

After enabling, read `donation_outcomes.write_speculative_limited` as a
change over equal windows. It counts write-budget, busy-writer and disk-room
refusals, a write declined because a file was already at its path, and
first-sight writes that gave way after their I/O began because their disk
room was needed by a proven write or was gone, without separating them. A
refusal before I/O spends no bytes and no write budget, whichever of those
caused it. A write that gave way was charged to the daily write cap
with no refund and left no checkpoint. The counter no longer always means "no
bytes and no write budget were spent": it means that for the refusals, and
the fleet reading cannot tell how many of its counts are the other kind (the
provider's `speculativeWritesYielded` stat can, in process only). Its growth
shows first-sight checkpoints going unwritten (a conversation none of whose
first-sight checkpoints was kept gets its first hit on the third request, as
with first sight off). It does not show a refused proven write. Refused proven
writes show in `write_priority_limited`,
`write_rate_limited` and `write_queue_full`. Raising the minimum lowers the
number of first-sight requests; the prompts it keeps are longer, and their
larger checkpoints need more of H.

The cost is provider writes, charged to each provider's daily write budget
in plaintext bytes, including a first-sight write that gave way after its
I/O began
([SSD write policy](../reference/ssd-kv-cache.md#size-and-eviction-rules)). A
gpt-oss-20b checkpoint file holds 49,152 B per token plus 6.03 MB of fixed
state, 308.0 MB at 6,144 tokens
([sizes per model](../architecture/prefix-cache.md#streamed-complete-checkpoints)).
The minimum token count is the control: a higher minimum writes for fewer,
longer prompts.

Watch three readings of `GET /v1/cache/status`, as changes over equal windows:

| Reading | Meaning | Limit |
|---|---|---|
| `.activation.first_sight` | Requests that were asked to keep a prefix; a subset of `.activation.planned` | It does not show that the provider wrote the prefix. `.lifecycle.donation_outcomes` shows what was written or skipped; a provider whose own minimum is above the kept boundary skips it, and so does a provider release that does not understand `cache_first_sight_tokens` (`skipped_novel`) |
| `.lifecycle.ssd_hits` per `.lifecycle.ssd_lookups` | Share of lookups that hit | First sight applies only to a prompt with no earlier shared boundary. A new conversation that begins with an already-seen opening of at least 1,024 tokens is a repeat: its provider still writes its deepest boundary, but its affinity key is the shared opening's |
| `.lifecycle.donation_outcomes.write_speculative_limited` | Speculative first-sight offers a provider declined before I/O because the store was more than the headroom below full, another checkpoint write was registered, the complete stored file did not fit the free disk budget, or a file was already at the checkpoint's path (no bytes or write budget spent); and admitted first-sight writes that gave way after I/O began because their disk room was needed by a proven write, including one queued in any store, or was gone (daily write cap charged, no refund, no checkpoint kept) | It does not say which cause applied or whether I/O happened, so growth alone does not show a refused proven write and cannot size the write cap spent on writes that gave way; on a store with a non-zero write cap whose headroom is smaller than the checkpoint every such offer lands here (small caps, above). It is reported only by a provider release that understands `cache_first_sight_tokens`, for requests that carry that field |

Three more limits
([details](../architecture/cache-aware-routing.md#first-sight)):

- A prompt needs more than 1,024 tokens; one of exactly 1,024 has no stride
  boundary to keep.
- With first sight on, the candidate scan of a novel request takes the provider
  lock and the tracker mutex per candidate, as a repeat request's scan already
  does. Compare first-content latency as in [Verification](#verification).
- Setting `0` does not restore the previous output byte for byte: the status
  JSON, Prometheus and Datadog keep a `first_sight` series at 0 and the boot
  line keeps `first_sight_min_tokens`.

1. **Record a baseline window.** The counters restart at zero with the
   coordinator, so compare changes over equal windows, not totals. Take two
   readings 30 minutes apart:

   ```bash
   first_sight_reading() {
     curl -fsS localhost:8080/v1/cache/status | jq '{
       first_sight: (.activation.first_sight // 0),
       planned: .activation.planned,
       ssd_lookups: .lifecycle.ssd_lookups,
       ssd_hits: .lifecycle.ssd_hits,
       skipped_novel: (.lifecycle.donation_outcomes.skipped_novel // 0),
       write_speculative_limited: (.lifecycle.donation_outcomes.write_speculative_limited // 0),
       write_priority_limited: (.lifecycle.donation_outcomes.write_priority_limited // 0),
       write_rate_limited: (.lifecycle.donation_outcomes.write_rate_limited // 0)}'
   }
   first_sight_window() {
     jq -n --slurpfile a "$1" --slurpfile b "$2" '$a[0] as $a | $b[0] as $b | {
       first_sight: ($b.first_sight - $a.first_sight),
       planned: ($b.planned - $a.planned),
       hits_per_lookup: (if $b.ssd_lookups > $a.ssd_lookups
         then ($b.ssd_hits - $a.ssd_hits) / ($b.ssd_lookups - $a.ssd_lookups) else null end),
       skipped_novel: ($b.skipped_novel - $a.skipped_novel),
       write_speculative_limited: ($b.write_speculative_limited - $a.write_speculative_limited),
       write_priority_limited: ($b.write_priority_limited - $a.write_priority_limited),
       write_rate_limited: ($b.write_rate_limited - $a.write_rate_limited)}'
   }
   first_sight_reading > /tmp/darkbloom-first-sight.before-1.json
   sleep 1800
   first_sight_reading > /tmp/darkbloom-first-sight.before-2.json
   first_sight_window /tmp/darkbloom-first-sight.before-1.json /tmp/darkbloom-first-sight.before-2.json \
     | tee /tmp/darkbloom-first-sight.before.json
   ```

2. **Set the minimum.** Choose the new value: a higher minimum such as `4096`,
   or `0` to turn first sight off. `refresh-env.sh` rejects duplicate keys, so
   replace the line when it exists and append it otherwise:

   ```bash
   FIRST_SIGHT_MIN_TOKENS=4096    # or 0 to turn first sight off
   sudo cp -p /etc/d-inference/env "/etc/d-inference/env.bak.$(date -u +%Y%m%dT%H%M%SZ)"
   if sudo grep -q '^EIGENINFERENCE_CACHE_ROUTING_FIRST_SIGHT_MIN_TOKENS=' /etc/d-inference/env; then
     sudo sed -i -E "s/^EIGENINFERENCE_CACHE_ROUTING_FIRST_SIGHT_MIN_TOKENS=.*/EIGENINFERENCE_CACHE_ROUTING_FIRST_SIGHT_MIN_TOKENS=${FIRST_SIGHT_MIN_TOKENS}/" /etc/d-inference/env
   else
     printf 'EIGENINFERENCE_CACHE_ROUTING_FIRST_SIGHT_MIN_TOKENS=%s\n' "$FIRST_SIGHT_MIN_TOKENS" | sudo tee -a /etc/d-inference/env >/dev/null
   fi
   sudo grep -c "^EIGENINFERENCE_CACHE_ROUTING_FIRST_SIGHT_MIN_TOKENS=${FIRST_SIGHT_MIN_TOKENS}\$" /etc/d-inference/env    # must print 1
   ```

   The value must be `0` or between 1,024 and 1,048,576. Anything else makes
   the coordinator log `cache routing configuration rejected` and exit before
   listening, and it does so even when `EIGENINFERENCE_CACHE_ROUTING_MODE` is
   `off`
   ([configuration.md](../reference/configuration.md#routing-admission-and-ttft)).

3. **Restart the coordinator** per [`coordinator-deploy.md`](coordinator-deploy.md).
   The boot line `provider-confirmed cache routing configured` reports the
   value as `first_sight_min_tokens`:

   ```bash
   sudo docker logs coordinator 2>&1 | grep -E 'cache routing configuration rejected|provider-confirmed cache routing configured'
   ```

4. **Observe an equal window** with the two functions from step 1 and compare
   it with the baseline:

   | Field | After raising the minimum | After `0` |
   |---|---|---|
   | `first_sight` | Lower than the baseline but above zero: one count per planned novel prompt of at least the new minimum | Zero |
   | `hits_per_lookup` | At or slightly below the baseline; a clear fall means the minimum now excludes prompts whose follow-ups were hitting | Lower than the baseline: a new conversation's second request runs cold again |
   | `skipped_novel` | Higher than the baseline, because fewer novel requests are written | Higher than the baseline |
   | `write_speculative_limited` | Fewer prompts qualify, so fewer speculative offers are made. Faster growth than the baseline is not by itself a reason to raise the minimum again: a refusal before I/O spends no bytes or write budget, and the counter separates neither its causes nor the writes that gave way after I/O began, which were charged to the daily write cap | Not growing |
   | `write_priority_limited` | Not growing faster than the baseline | Not growing faster than the baseline |
   | `write_rate_limited` | Not growing faster than the baseline | Not growing faster than the baseline; if it still grows, providers' whole daily budget is exhausted by other writes |

   Also check first-content latency as in [Verification](#verification);
   first sight changes placement only among candidates that already tie.

**Roll back** by restoring the backup from step 2 and restarting, or by
deleting the line to return to the default of 1,024. Checkpoints already
written stay on their providers until they expire and remain usable by later
repeats.

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
