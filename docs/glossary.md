# Glossary — the one name for each thing

> Last updated: 2026-09-04 · commit `ac60c5ada`

Canonical terms used across the docs and the code, one line each, with the page
that owns the full definition. Use these spellings everywhere (including code
identifiers and message `type` strings, which are quoted exactly). Entries
define the term and name the constants involved; the values live only on the
owner page. Terms are grouped by concern and alphabetical within a group.

## Parties and components

| Term | Meaning | Owner page |
|---|---|---|
| **Admin UI** | Internal read-only operations dashboard (`admin-ui/`), Basic-Auth gated, SELECT-only SQL against a replica | [`architecture/components/admin-ui.md`](architecture/components/admin-ui.md) |
| **Console** | The web app at `console.darkbloom.dev` (`console-ui/`): keys, chat, billing, provider dashboards; talks to the coordinator only through its own `/api/*` relays | [`architecture/components/console-ui.md`](architecture/components/console-ui.md) |
| **Consumer** | Anyone calling the HTTP API with an API key or Privy JWT | [`architecture/components/consumer.md`](architecture/components/consumer.md) |
| **Coordinator** | The Go control plane (`coordinator/`): HTTP API, provider WebSocket, routing, billing, persistence. One process per environment (`api.darkbloom.dev`, `api.dev.darkbloom.xyz`) | [`architecture/components/coordinator.md`](architecture/components/coordinator.md) |
| **Landing** | Static marketing site (`landing/`) with the earnings calculator | [`architecture/components/console-ui.md`](architecture/components/console-ui.md) |
| **Provider** (node) | A Mac running the `darkbloom` CLI (`provider-swift/`), connected to the coordinator over `/ws/provider`, serving models | [`architecture/components/provider.md`](architecture/components/provider.md) |
| **Prompt-contract sidecar** (`promptsidecar`) | Rust child process of the coordinator (`EIGENINFERENCE_PROMPT_SIDECAR_ENABLED`) that derives deterministic, provider-compatible token boundaries for exact-cache routing; always fails cold, never blocks inference | [`architecture/prompt-contract-sidecar.md`](architecture/prompt-contract-sidecar.md) |

## Identity, trust, and encryption

| Term | Meaning | Owner page |
|---|---|---|
| **APNs code identity** (code attestation) | Proof that the provider process is the genuine signed binary: a nonce sealed to the process key is pushed via Apple Push Notification service and signed back with the Secure Enclave key. Flags `CodeAttested` / `FreshCodeAttested`; throttle and resume constants (`reuseWindow`, `backgroundPushCooldown`, `alertPushCooldown`, `maxAttempts`, `challengeValidity`) are in the owner section | [`architecture/security/attestation.md#flag--apns-code-identity`](architecture/security/attestation.md#flag--apns-code-identity) |
| **Challenge** (SE liveness challenge) | Coordinator-initiated Secure Enclave signature check on a fixed cadence (`DefaultChallengeInterval`); a provider is routable while its last verified challenge is younger than `challengeFreshnessMaxAge`, and consecutive failures up to `MaxFailedChallenges` untrust it | [`architecture/security/attestation.md#layer-2--periodic-challenge`](architecture/security/attestation.md#layer-2--periodic-challenge) |
| **Enrollment** | Getting a Mac into Darkbloom's MDM (SCEP profile, webhook) so `SecurityInfo` can be read | [`architecture/security/enrollment.md`](architecture/security/enrollment.md) |
| **Hop-by-hop encryption** | The privacy model: three independent NaCl `box` (X25519 + XSalsa20-Poly1305) hops — consumer → coordinator, coordinator → provider, provider → coordinator. The coordinator decrypts in memory to route and bill; it does not retain prompt content | [`architecture/security/encryption.md`](architecture/security/encryption.md) |
| **MDA** (Managed Device Attestation) | Apple-signed device attestation obtained through MDM; recorded as the flag `mda_verified`, not a trust level | [`architecture/security/attestation.md`](architecture/security/attestation.md) |
| **MDM SecurityInfo** | The Apple MDM query whose SIP / Secure Boot fields are the *only* grant of `hardware` trust | [`architecture/security/attestation.md`](architecture/security/attestation.md) |
| **Privacy capabilities** | Provider-declared invariants sent at registration (`privacy_capabilities`), required for private-text routing | [`reference/protocol-messages.md`](reference/protocol-messages.md) |
| **Registration blob** | Secure-Enclave-signed attestation a provider sends when it registers; Layer 1 of trust | [`architecture/security/attestation.md`](architecture/security/attestation.md) |
| **Release policy** | Coordinator gate that only routes providers running an active release (`EIGENINFERENCE_RELEASE_POLICY_MODE`) | [`operations/release-policy-rollout.md`](operations/release-policy-rollout.md) |
| **Runtime manifest** | Coordinator policy listing, per template name (`mlx_metallib` included), every hash accepted across active releases; a provider whose reported metallib is not in the set stays connected but unroutable | [`architecture/security/attestation.md#runtime-manifest`](architecture/security/attestation.md#runtime-manifest) |
| **Sealed request** | A consumer request whose body is NaCl-boxed to the coordinator key; responses carry `X-Eigen-Sealed` / `X-Eigen-Sealed-Kid` | [`architecture/security/encryption.md`](architecture/security/encryption.md) |
| **Trust level** | Closed enum on a provider: `none`, `self_signed`, `hardware` (`registry.TrustLevel`). Routing applies a floor (`MinTrustLevel`, set by `EIGENINFERENCE_MIN_TRUST`) | [`architecture/security/attestation.md#trust-levels`](architecture/security/attestation.md#trust-levels) |
| **Trust reuse** | Re-granting `hardware` after a reconnect from durable device evidence — a recent live MDM proof (`defaultTrustReuseWindow`) or a short coordinator-measured offline gap (`defaultTrustReuseReconnectGap`) — once a fresh signed challenge verifies, instead of a new `SecurityInfo` round-trip | [`architecture/security/attestation.md#layer-3--mdm-securityinfo-the-hardware-grant`](architecture/security/attestation.md#layer-3--mdm-securityinfo-the-hardware-grant) |

## Routing and scheduling (coordinator)

| Term | Meaning | Owner page |
|---|---|---|
| **Activation floor** / **activation reserve** | Memory the engine needs beyond weights and KV: the provider default `defaultActivationReserveBytes`, overridden per model by `measuredActivationFloorsBytes`; mirrored by the coordinator in `servability.go` | [`architecture/hardware-support.md#constants`](architecture/hardware-support.md#constants) |
| **Budget clamp** | After a capacity 503, a slot is treated as full until a later heartbeat shows headroom and a request is accepted; fails open after a fixed interval | [`architecture/routing.md`](architecture/routing.md) |
| **Cost model** | The additive penalty score used to rank eligible providers (`coordinator/registry/scheduler.go` constants) | [`architecture/routing.md`](architecture/routing.md) |
| **Drain trigger** | Why a queued request was released to a provider: `heartbeat`, `idle`, `challenge`, `load`, `disconnect`, `kick`, `unknown` | [`architecture/scheduling.md`](architecture/scheduling.md) |
| **Gate reason** (`GateReason`) | Closed vocabulary naming why a provider was excluded from a route (e.g. `offline`, `untrusted`, `challenge_stale`) | [`architecture/routing.md`](architecture/routing.md) |
| **Hedged dispatch** | Speculative second dispatch to a backup provider when the first has not produced content by a computed offset | [`architecture/routing.md`](architecture/routing.md) |
| **Heartbeat** / **eviction** | The provider's periodic state report over the WebSocket, sent every `heartbeat_interval_secs`; a provider whose heartbeats stop is marked stale by the coordinator's sweep and evicted after consecutive stale sweeps | cadence default: [`provider/cli-reference.md#providertoml-keys-read-by-the-cli`](provider/cli-reference.md#providertoml-keys-read-by-the-cli); timeout, sweep and eviction: [`architecture/scheduling.md#heartbeat-cadence-and-eviction`](architecture/scheduling.md#heartbeat-cadence-and-eviction) |
| **Queue** (per-model) | Bounded wait for capacity (`defaultQueueMaxDepth`, `defaultQueueMaxWait`); overflow is a 429 with `Retry-After` | [`architecture/scheduling.md`](architecture/scheduling.md) |
| **Reputation** | Weighted, exponentially smoothed provider score shown in stats; not a cost-model term | [`architecture/routing.md`](architecture/routing.md) |
| **Selection path** | Label for how the winner was chosen among near-ties: `unique_min`, `tie_queue`, `tie_pending`, `cache_tiebreak`, `random` | [`architecture/routing.md`](architecture/routing.md) |
| **Self-route** | An owner's requests routed only to their own providers (trust floor relaxed to `none`) | [`provider/self-route.md`](provider/self-route.md) |
| **Servability** (`PredictServable`) | Structural early-429 predictor: can this prompt fit any provider's token budget at all | [`architecture/routing.md`](architecture/routing.md) |
| **Slot** (model slot) | One loaded model instance on a provider, at most `max_model_slots` per provider. Slot states decide warm/loaded/ineligible | [`architecture/scheduling.md`](architecture/scheduling.md) |
| **Warm pool** | Controller that keeps a Little's-Law-derived number of idle warm slots per model | [`architecture/scheduling.md`](architecture/scheduling.md) |

## Billing

| Term | Meaning | Owner page |
|---|---|---|
| **API key** | Consumer credential starting `sk-db-` (`store.KeyPrefix`), sent as `Authorization: Bearer`; stored only as a hash and cached on lookup for `apiKeyCacheTTL`. How to create and manage one: [`consumer/authentication.md`](consumer/authentication.md) | [`reference/api-contracts.md#api-key-shapes`](reference/api-contracts.md#api-key-shapes) |
| **Base rewards** | Additive provider floor income; implemented, gated off by default (`EIGENINFERENCE_BASE_REWARDS`) | [`architecture/billing.md`](architecture/billing.md) |
| **Ledger** / **LedgerEntryType** | Append-only money movements; a closed enum of entry types | [`architecture/billing.md`](architecture/billing.md) |
| **micro-USD** | The integer unit of every stored amount; conversion in the owner page | [`reference/pricing-model.md#units`](reference/pricing-model.md#units) |
| **Platform fee** | Stated once, as an invariant, in [`architecture/billing.md#invariants`](architecture/billing.md#invariants); never restated | [`architecture/billing.md`](architecture/billing.md) |
| **Reservation** | Pre-authorised hold for a request (estimated prompt + `max_tokens` at platform price) that settles to actual usage and refunds the rest | [`architecture/billing.md`](architecture/billing.md) |
| **Service account** | Account with `RoleService` = `"service"`; whether its requests take ledger reservations is controlled by `EIGENINFERENCE_SERVICE_RESERVATIONS_ENABLED` | [`architecture/billing.md`](architecture/billing.md) |
| **Spend cap** | Per-key daily/monthly limit enforced at admission; exhausting it is one of the 402 responses (types and codes in [`architecture/billing.md#payment-required-responses`](architecture/billing.md#payment-required-responses)) | [`consumer/billing.md`](consumer/billing.md) |
| **Withdrawable balance** | The provider-earned portion of a balance that Stripe Connect payouts may draw on; always ≤ balance | [`architecture/billing.md`](architecture/billing.md) |

## Inference engine (provider)

| Term | Meaning | Owner page |
|---|---|---|
| **CBv2** (continuous batching v2) | The engine scheduler in `libs/mlx-swift-lm` (`ContinuousBatchingV2/`) that admits, prefills, and decodes many requests per step | [`architecture/inference.md`](architecture/inference.md) |
| **EngineV2** | The provider-side bridge and slot factory that hosts CBv2 (`EngineV2Bridge`, `EngineV2SlotFactory`) | [`architecture/inference.md`](architecture/inference.md) |
| **KV cache** (contiguous / paged) | Attention key/value storage per request; `engine_v2_kv_backend` selects the backend (`auto`, `contiguous`, `paged`); paged storage is organised in fixed-size pages (`pageSize`) | [`architecture/prefix-cache.md`](architecture/prefix-cache.md) |
| **metallib** | Compiled Metal shader library (`mlx.metallib`) that must match the pinned `libs/mlx` source; fetched by `scripts/fetch-metallib.sh` | [`developer/build.md`](developer/build.md) |
| **MLX** / **mlx-swift** / **mlx-swift-lm** | The three pinned submodules under `libs/`: Apple-silicon array framework, its Swift bindings, and the LLM layer that contains CBv2 | [`architecture/components/mlx-swift.md`](architecture/components/mlx-swift.md) |
| **Model manifest** / **registry** | JSON describing a model's files, hashes, capabilities, and runtime parameters; served from R2 and registered through `/v1/admin/models/register` | [`reference/model-registry-format.md`](reference/model-registry-format.md) |
| **MTP** (multi-token prediction) | Speculative decoding with a draft head (Qwen3.5 embedded head, Gemma 4 assistant); kill switch `DARKBLOOM_CBV2_MTP` | [`architecture/inference.md`](architecture/inference.md) |
| **Prefix cache** | Reuse of KV blocks for a shared prompt prefix at block granularity (`defaultBlockSize`); RAM tier plus optional SSD tier | [`architecture/prefix-cache.md`](architecture/prefix-cache.md) |
| **SSD cache** (DBK3) | On-disk prefix-cache tier under `darkbloom/kv3`, schema v3, `.dbk3` files | [`reference/ssd-kv-cache.md`](reference/ssd-kv-cache.md) |
| **Unified memory cap** (`hardCapBytes`) | Ceiling for weights + KV + activations: a fraction of physical unified memory (`defaultCapFraction`), never closer than `minimumReserveBytes` to physical | [`architecture/hardware-support.md#cap-and-reserves-unifiedmemorycap`](architecture/hardware-support.md#cap-and-reserves-unifiedmemorycap) |

## Observability and operations

| Term | Meaning | Owner page |
|---|---|---|
| **Freshness stamp** | Line 3 of every doc: `> Last updated: YYYY-MM-DD · commit <sha>` — the date the content was verified and the code commit it was verified against | [`AGENTS.md`](AGENTS.md) |
| **Request outcome** | Closed taxonomy classifying how every request ended (success, client, capacity, provider fault…) used by rejection telemetry | [`architecture/request-outcome-observability.md`](architecture/request-outcome-observability.md) |
| **SHORT_SHA** | 7-character commit prefix that Cloud Build uses as the coordinator image tag in production | [`operations/coordinator-deploy.md`](operations/coordinator-deploy.md) |
| **System profiler** | Per-attempt request waterfall, provider/engine profile, and fleet snapshots recorded by the coordinator | [`architecture/system-profiler.md`](architecture/system-profiler.md) |
| **Telemetry event** | Allow-listed, schema-versioned event emitted by coordinator, provider, or console; wire types mirrored in Go, Swift, and TypeScript | [`reference/telemetry-schema.md`](reference/telemetry-schema.md) |
| **X-Timing** | Response header: JSON object of `*_us` segment durations for a committed inference response | [`reference/api-contracts.md`](reference/api-contracts.md) |
