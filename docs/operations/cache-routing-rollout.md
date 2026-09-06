# Cache-aware routing: activation, ramp and rollback

> Last updated: 2026-09-06 · commit `2eebb5412`

How to turn provider-confirmed prefix-cache routing on for the production
coordinator, widen its activation bounds one at a time, and turn it off again.
Written for an operator with production access; how the feature works is in
[`../architecture/cache-aware-routing.md`](../architecture/cache-aware-routing.md).

## When to use

- First production activation of `EIGENINFERENCE_CACHE_ROUTING_MODE=on`.
- Raising `EIGENINFERENCE_CACHE_ROUTING_PERCENT` or
  `EIGENINFERENCE_CACHE_ROUTING_MAX_PLAN_QPS` after a clean observation window.
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
Leave the provider's `DARKBLOOM_PREFIX_CACHE` unset to use its Qwen-only default.
An explicit affirmative value opts other supported models into SSD caching;
the coordinator allowlist restricts network participation but does not override
that local provider setting.

The mode remains global, and `PERCENT` samples a deterministic cohort keyed on
account + resolved model + provider-bound body (`cacheActivationCohort`,
`coordinator/registry/cache_activation.go`). Within the admitted artifact subset,
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
  nothing.
- Datadog open on the `exact_cache.*` gauges
  (`emitExactCacheDDGauges`, `coordinator/api/exact_cache_metrics.go`) and the
  `routing.cache_selection_terminal`, `routing.cache_selection_precision` and
  `routing.cache_selection_discount_ms` series (`coordinator/api/provider.go`).

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
   `coordinator/registry/cache_activation.go`). Take a root-only backup, then
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
   `max_discount_ms` and `max_cost_fraction` (`coordinator/cmd/coordinator/main.go`);
   `null` means no optional clipping beyond avoidable prefill work. A rejected configuration logs `cache routing configuration rejected` and
   exits before listening.

   ```bash
   sudo docker logs coordinator 2>&1 | grep -E 'cache routing configuration rejected|provider-confirmed cache routing configured'
   ```

5. **Widen one bound at a time.** After a clean observation window
   (Verification below shows hits and no sidecar distress), raise **either**
   `EIGENINFERENCE_CACHE_ROUTING_PERCENT` **or**
   `EIGENINFERENCE_CACHE_ROUTING_MAX_PLAN_QPS` — never both in one change —
   by repeating steps 3–4 with the new value, and observe again before the
   next step.

## Verification

```bash
curl -fsS localhost:8080/v1/cache/status | jq -e \
  '.routing_mode == "on" and .activation.percent == 1 and .activation.max_plan_qps == 1 and .sidecar.ready'
```

Adjust the two numbers to the bounds you set. Then, over the observation
window (fields from `CacheRoutingActivationStatus`,
`coordinator/registry/cache_activation.go`, and `CacheRoutingLifecycleStatus`,
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
