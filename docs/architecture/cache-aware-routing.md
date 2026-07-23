# Exact Prefix Cache Routing

## Guarantee

Cache routing is an optimization, never an inference dependency. When routing is
`off`, the coordinator emits no reusable remote scope, tracks no receipts, and
applies no cache discount. When routing is `on`, only exact text-token prefix
proofs from protocol-v2 providers can affect selection. Unsupported providers,
multimodal requests, sidecar failures, contract mismatches, stale evidence, and
invalid receipts all use normal cold routing.

The provider's encrypted SSD cache is the only production reusable prefix tier.
No caller field, session identifier, JSON-body hash, probabilistic conversation
anchor, or coordinator heuristic establishes cache ownership.

## Request flow

```mermaid
flowchart LR
  A[Final provider-bound text body] --> B[Local prompt-contract sidecar]
  B --> C[Exact token boundaries]
  C --> D[Normal provider eligibility gates]
  D --> E[Longest provider-confirmed boundary]
  E --> F[Bounded net staging discount]
  F --> G[Encrypted dispatch]
  G --> H[Provider recomputes token-chain proof]
  H --> I[SSD lookup or durable donation]
  I --> J[Monotonic v2 evidence]
```

The coordinator calls the local Rust sidecar only after alias resolution, tool
normalization, endpoint lowering, output-bound injection, and construction of
the final provider-bound body. The sidecar returns the prompt contract identity,
exact token count, and complete block-chain boundaries. It never returns or logs
the normalized prompt, tokens, or hashes outside the local response contract.

Sidecar timeout, crash, malformed output, unavailable artifacts, and dynamic-time
templates return a non-participating plan. The request still dispatches.
Multimodal requests never produce a participating plan.

## Identity and isolation

One cache plan contains:

- the verified model aggregate hash;
- the prompt contract identity;
- an opaque account/build scope;
- the exact prompt token count;
- ordered complete block-chain boundaries.

The provider-visible scope is a domain-separated HMAC over authenticated account,
concrete model build, aggregate hash, prompt contract, and block-hash contract.
The provider does not infer remote scope from `prompt_cache_key`, `user`, or any
other caller-controlled body field.

Coordinator route keys are separate domain-separated HMACs over the opaque scope,
aggregate hash, prompt contract, provider cache epoch, boundary token count, and
provider-confirmed chain hash. Route keys, account identifiers, raw boundaries,
and prompts are not persisted or attached to telemetry.

## Protocol v2 proof

Every ready model advertises a connection-scoped capability containing:

- concrete model ID and actual post-load aggregate hash;
- prompt contract ID;
- block hash version and block size;
- durable cache epoch;
- enabled and ready state.

The coordinator accepts the capability only when it matches the provider's
registered model inventory and supported block contract. A cache attempt binds
the live provider connection, request, model, plan, capability, nonce, and
expiry.

The provider recomputes the token-chain anchor from the body it actually
tokenizes. Lookup evidence carries the prompt anchor and optional matched anchor.
Durable-ready evidence carries the input-prompt anchor plus, when available, the
final generated-continuation anchor. Evidence sequence numbers are allocated by
the provider's durable epoch store and must increase strictly for each
provider/model/epoch.

A prompt-proof mismatch quarantines that exact capability. The request continues
without preference. A changed capability or cache epoch may participate only
after a fresh valid proof.

## Holder lifecycle

A holder is created only by a valid SSD hit or by a durable-ready callback after
the encrypted DBK3 blocks have been written, indexed, reopened, authenticated,
and found readable. It records the live provider connection, model, aggregate
hash, prompt contract, cache epoch, exact anchor, recompute requirement, expected
saved tokens, measured staging cost, and bounded expiry.

Evidence is removed or made unreachable on:

- provider disconnect or live-connection replacement;
- capability, contract, aggregate hash, or epoch change;
- proof mismatch;
- verified miss or corruption for the attempted boundaries;
- holder expiry or deterministic cap eviction;
- routing transition to `off`.

Provider capacity eviction rotates the model cache epoch, coarsely invalidating
all old holders for that model. This is intentionally conservative.

Attempts remain briefly after inference terminal state because encrypted SSD
write-behind can finish later. Attempt and holder maps are memory-only, capped,
and heap-evicted. V1 receipts remain decodable for mixed-version safety but
cannot mutate routing evidence.

## Scheduler

All ordinary trust, model, trait, memory, token-budget, queue, cooldown, health,
and time-to-first-token gates run first. For each eligible provider, the router
looks up its longest live exact boundary under the provider's current capability.

```text
saved_ms = exact_saved_tokens / provider_prefill_tps * 1000
net_ms = max(0, saved_ms - measured_ssd_stage_ms)
discount = min(net_ms, configured_max_ms, baseline_cost * configured_fraction)
adjusted_cost = baseline_cost - discount
```

Unknown or non-positive staging cost yields no hint. There is no confidence
multiplier, hard affinity, hypothetical winner, dedicated-cache mode, or stacking
of multiple boundaries. A busy cached provider still loses when its adjusted
cost is worse.

Cache-participating attempts are excluded from cold-prefill calibration and
full-prefill reputation samples. Terminal cache metrics use bounded categorical
tags only.

`GET /v1/cache/status` exposes only aggregate rollout state: activation and
lifecycle counters; sidecar enabled/running/ready, child generation, categorical
restart reason, failure streak, timeouts/overloads/RSS, cold/warm contract loads,
and planner outcomes; preload generation/counts; prompt artifact
ready/pending/failed counts; protocol 0/1/2 provider counts; ready v2
provider-model count; and bounded holder/attempt counts. It never includes model
IDs, provider IDs, accounts, scopes, prompts, tokens, or chain hashes.
The response and gauge projection are implemented in
`coordinator/api/exact_cache_status.go` and `exact_cache_metrics.go`; bounded artifact aggregation lives in
`coordinator/promptcontract/provisioner.go:Counts`, protocol distribution in
`coordinator/registry/cache_status.go:PrefixCacheProtocolStatus`, and holder /
attempt counts in `coordinator/registry/cache_routing.go:CacheRoutingStateCounts`.

For each selected hint, terminal correlation stays on the in-memory
`PendingRequest` and emits bounded tags:
`selected`, `lookup_outcome`, `cache_read`, `tier`, and `result`. This measures
selected-holder precision and actual cached-read success without using an
identifier as a metric tag
(`coordinator/registry/registry.go:PendingRequest`,
`coordinator/api/provider.go:cacheSelectionTerminalTags`).

## Configuration and rollback

| Environment variable | Default | Purpose |
|---|---:|---|
| `EIGENINFERENCE_CACHE_ROUTING_MODE` | `off` | `off` or `on` |
| `EIGENINFERENCE_CACHE_ROUTING_PERCENT` | `100` | Deterministic percentage of otherwise eligible requests admitted to planning while mode is `on` |
| `EIGENINFERENCE_CACHE_ROUTING_MAX_PLAN_QPS` | `0` | Process-local sidecar planning cap while mode is `on`; `0` is unlimited |
| `EIGENINFERENCE_CACHE_ROUTING_TTL` | `10m` | Holder lifetime |
| `EIGENINFERENCE_CACHE_ROUTING_MAX_HOLDERS` | `4` | Holders per boundary |
| `EIGENINFERENCE_CACHE_ROUTING_MAX_DISCOUNT_MS` | `1000` | Absolute discount cap |
| `EIGENINFERENCE_CACHE_ROUTING_MAX_COST_FRACTION` | `0.35` | Relative discount cap |
| `EIGENINFERENCE_CACHE_MASTER_KEY` | none | 32-byte base64 or hex HMAC key |

`on` fails startup when the master key is missing or malformed. `off` requires no
key and clears all in-memory evidence when applied. The product mode remains
strictly binary: percentage and QPS are operational caps inside `on`, not extra
modes. Sampling is a keyed, deterministic cohort over account, resolved model,
and provider-bound request body. Repeating the same exact request therefore
stays in the same cohort, allowing a sampled cold miss to donate and later hit,
without logging or exporting the cohort input. The QPS cap only declines cache
planning; ordinary inference continues cold. Provider caching has one local kill
switch, `DARKBLOOM_PREFIX_CACHE`; unset defaults to encrypted SSD on.

Rollout starts with coordinator routing `off`. Verify sidecar health, contract
parity, provider capability identity, and proof mismatch rate before enabling
`on` in an isolated development or canary environment. The first production
activation uses `PERCENT=1` and `MAX_PLAN_QPS=1`; raise one bound at a time only
after a clean observation window. Rollback always sets routing to `off` before
rolling back binaries.

The v0.7.12 release does not activate routing. Providers with
`cbv2-frozen-full-3` contiguous native-float support can advertise Gemma 4 and GPT-OSS
as protocol-v2 models only after SSD scan readiness
(`provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCache.swift:325-343`,
`provider-swift/Sources/ProviderCore/Coordinator/CoordinatorClientState.swift:176-184`,
`provider-swift/Sources/ProviderCore/Coordinator/CoordinatorClient+Registration.swift:27-36`);
paged hybrid slots remain v1/cold
(`provider-swift/Sources/ProviderCore/Inference/PrefixCachePolicy.swift:110-129`).
Production activation is still a separate operational decision:
positive durable-hit evidence, stable correlation telemetry, healthy prompt
artifacts, routing-mode enablement, and a separately provisioned 256-bit cache
master key remain required.
