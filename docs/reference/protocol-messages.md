# Provider ↔ coordinator protocol messages

> Last updated: 2026-09-05 · commit `055a76364`

Every JSON frame on the provider WebSocket (`GET /ws/provider`), with the Go
type, the Swift type, and the presence rule for each field. Go is the canon
(`coordinator/protocol/messages.go`, `capacity.go`, `profile.go`); Swift mirrors
it (`provider-swift/Sources/ProviderCore/Protocol/Messages.swift`, `Types.swift`,
`InferenceProfile.swift`). There are 16 provider→coordinator and 10
coordinator→provider message types; nothing else is accepted.

Conventions: **req** = always present; **opt** = Go `omitempty`, Swift
`encodeIfPresent` (absent when nil, and for scalars when zero/empty unless a
row says otherwise); **ptr** = Go pointer with `omitempty`, so absent ≠ zero.
JSON keys are snake_case and identical in the Go tags and the Swift
`CodingKeys`.

## Envelope and the single-parse rule

| Rule | Go | Swift |
|---|---|---|
| Discriminator | top-level `"type"` string | same |
| Decode | `DecodeProviderMessage` first tries the single-walk chunk scanner (`coordinator/protocol/chunk_scan.go`, `scanChunkFrame`); unsupported shapes fall back to `ProviderMessage.UnmarshalJSON` (`coordinator/protocol/messages.go`), which reads `type` with `scanTopLevelString` (`coordinator/protocol/type_scan.go`), a byte walk over the top-level keys, then `json.Unmarshal`s the frame **once** into the concrete struct | `ProviderMessage.init(from:)` / `CoordinatorMessage.init(from:)` decode `TypeValue` then switch (`Messages.swift`) |
| Scanner fallback | escaped string, non-string value, malformed input or missing key → decode a `struct{ Type string }` envelope first (the historic double parse), so error behaviour is unchanged | — |
| Unknown type | `protocol: unknown message type %q` | `DecodingError` — the decoder **throws**, so the coordinator version-gates `desired_models`, `prefetch_model`, `load_model` and `capacity_probe` sends |
| Tests | `coordinator/protocol/type_scan_test.go` (`TestProviderMessageUnmarshalScanEquivalence`), `messages_envelope_test.go`, `messages_bench_test.go` | `provider-swift/Tests/ProviderCoreTests/ProtocolTests.swift` |

## Message inventory

| Direction | `type` | Go struct | Swift case |
|---|---|---|---|
| provider → coordinator | `register` | `RegisterMessage` | `ProviderMessage.register` (`Register`) |
| provider → coordinator | `heartbeat` | `HeartbeatMessage` | `.heartbeat` (`Heartbeat`) |
| provider → coordinator | `inference_accepted` | `InferenceAcceptedMessage` | `.inferenceAccepted` |
| provider → coordinator | `inference_response_chunk` | `InferenceResponseChunkMessage` | `.inferenceResponseChunk` |
| provider → coordinator | `inference_complete` | `InferenceCompleteMessage` | `.inferenceComplete` |
| provider → coordinator | `inference_error` | `InferenceErrorMessage` | `.inferenceError` |
| provider → coordinator | `attestation_response` | `AttestationResponseMessage` | `.attestationResponse` |
| provider → coordinator | `code_attestation_response` | `CodeAttestationResponseMessage` | `.codeAttestationResponse` |
| provider → coordinator | `load_model_status` | `LoadModelStatusMessage` | `.loadModelStatus` |
| provider → coordinator | `prefetch_model_status` | `PrefetchModelStatusMessage` | `.prefetchModelStatus` |
| provider → coordinator | `models_update` | `ModelsUpdateMessage` | `.modelsUpdate` |
| provider → coordinator | `prefix_cache_lookup` | `PrefixCacheLookupMessage` | `.prefixCacheLookup` |
| provider → coordinator | `prefix_cache_ready` | `PrefixCacheReadyMessage` | `.prefixCacheReady` |
| provider → coordinator | `prefix_cache_lookup_v2` | `PrefixCacheLookupV2Message` | `.prefixCacheLookupV2` |
| provider → coordinator | `prefix_cache_ready_v2` | `PrefixCacheReadyV2Message` | `.prefixCacheReadyV2` |
| provider → coordinator | `capacity_quote` | `CapacityQuoteMessage` (`capacity.go`) | `.capacityQuote` |
| coordinator → provider | `inference_request` | `InferenceRequestMessage` | `CoordinatorMessage.inferenceRequest` |
| coordinator → provider | `cancel` | `CancelMessage` | `.cancel` |
| coordinator → provider | `attestation_challenge` | `AttestationChallengeMessage` | `.attestationChallenge` |
| coordinator → provider | `code_attestation_resume_challenge` | `CodeAttestationResumeChallenge` | `.codeAttestationResumeChallenge` |
| coordinator → provider | `runtime_status` | `RuntimeStatusMessage` | `.runtimeStatus` |
| coordinator → provider | `load_model` | `LoadModelMessage` | `.loadModel` |
| coordinator → provider | `prefetch_model` | `PrefetchModelMessage` | `.prefetchModel` |
| coordinator → provider | `desired_models` | `DesiredModelsMessage` | `.desiredModels` |
| coordinator → provider | `trust_status` | `TrustStatusMessage` | `.trustStatus` |
| coordinator → provider | `capacity_probe` | `CapacityProbeMessage` (`capacity.go`) | `.capacityProbe` |

There is no `unload` or `unload_model` message; see
[Model unloading](#model-unloading-no-message).

## Provider → coordinator

### `register`

Go `RegisterMessage` · Swift `ProviderMessage.Register`. Sent once per
connection, first.

| JSON key | Go | Swift | Presence | Notes |
|---|---|---|---|---|
| `hardware` | `Hardware` | `HardwareInfo` | req | [`hardware`](#hardware) |
| `models` | `[]ModelInfo` | `[ModelInfo]` | req | [`models[]`](#models) |
| `backend` | `string` | `String` | req | e.g. `"mlx-swift"`; the coordinator sends `load_model`, `prefetch_model` and `desired_models` only to `backend == "mlx-swift"` |
| `runtime_capabilities` | `[]string` | `[ProviderRuntimeCapability]` | opt | connection-scoped runtime capabilities; Swift omits when empty |
| `version` | `string` | `String?` | opt | provider binary version, e.g. `"0.2.31"` |
| `public_key` | `string` | `String?` | opt | base64 X25519 public key `K` for E2E encryption |
| `encrypted_response_chunks` | `bool` | `Bool` | opt | Swift encodes only when `true` |
| `attestation` | `json.RawMessage` | `RawJSON?` | opt | Secure Enclave attestation blob; raw bytes kept for signature verification |
| `prefill_tps`, `decode_tps` | `float64` | `Double?` | opt | benchmark figures. The v0.8.16 provider never sets them (`registrationMessage`, `provider-swift/Sources/ProviderCore/Coordinator/CoordinatorClientCodec.swift`); the scheduler falls back to `defaultPrefillToDecodeRatio` |
| `auth_token` | `string` | `String?` | opt | device-linked provider token |
| `private_only` | `bool` | `Bool` | opt | owner self-route only; Swift encodes only when `true` |
| `prefix_cache_protocol` | `int` | `Int?` | opt | Swift omits nil/0 |
| `prefix_cache_v2_models` | `[]PrefixCacheV2Capability` | `[PrefixCacheV2Capability]?` | opt | [prefix-cache objects](#prefix-cache-objects) |
| `prefix_cache_memory_models` | `[]PrefixCacheV2Capability` | `[PrefixCacheV2Capability]?` | opt | additive resident-slot capabilities; independent epoch and no SSD durability claim; older coordinators ignore it |
| `prefix_cache_statuses` | `*[]PrefixCacheModelStatus` | `[PrefixCacheModelStatus]?` | ptr | omitted (legacy provider) ≠ `[]` (authoritative empty set) |
| `prefix_cache_donation_outcomes` | `*[]PrefixCacheDonationOutcomeCount` | `[PrefixCacheDonationOutcomeCount]?` | ptr | same pointer rule |
| `tool_constraint_protocol` | `int` | `Int?` | opt | forced-tool grammar protocol version; Swift omits nil/0 |
| `tool_constraint_models` | `[]string` | `[String]?` | opt | concrete model IDs the provider enforces |
| `apns_device_token` | `string` | `String?` | opt | hex APNs token for the `E_K(nonce)` code-identity push |
| `apns_environment` | `string` | `String?` | opt | `"production"` or `"development"` |
| `python_hash`, `runtime_hash` | `string` | `String?` | opt | SHA-256 |
| `template_hashes` | `map[string]string` | `[String: String]` | opt | template name → SHA-256; Swift omits when empty |
| `privacy_capabilities` | `*PrivacyCapabilities` | `PrivacyCapabilities?` | opt | [`privacy_capabilities`](#privacy_capabilities); providers `< v0.6.31` also send `hypervisor_active` inside it, which Go drops |
| `wallet_address` | — | `String?` | Swift only | legacy key; Go has no field and drops it |

#### `hardware`

Go `Hardware` · Swift `HardwareInfo`. All fields required.

| JSON key | Go | Swift |
|---|---|---|
| `machine_model` | `string` | `String` |
| `chip_name` | `string` | `String` |
| `chip_family` | `string` | `ChipFamily` (`"M1"`, `"M2"`, `"M3"`, `"M4"`, `"M5"`, `"Unknown"`; `Protocol/Enums.swift`) |
| `chip_tier` | `string` | `ChipTier` (`"Base"`, `"Pro"`, `"Max"`, `"Ultra"`, `"Unknown"`) |
| `memory_gb` | `int` | `UInt64` |
| `memory_available_gb` | `float64` | `UInt64` |
| `cpu_cores` | `CPUCores` `{total, performance, efficiency}` (`int`) | `CpuCores` |
| `gpu_cores` | `int` | `UInt32` |
| `memory_bandwidth_gbs` | `float64` | `UInt32` |

#### `models[]`

Go `ModelInfo` · Swift `ModelInfo` (`Types.swift`).

| JSON key | Go | Swift | Presence | Notes |
|---|---|---|---|---|
| `id` | `string` | `String` | req | catalog build id |
| `size_bytes` | `int64` | `UInt64` | req | |
| `model_type` | `string` | `String?` | req in Go | |
| `quantization` | `string` | `String?` | req in Go | |
| `weight_hash` | `string` | `String?` | opt | SHA-256 of the weight files |
| `is_vision` | `bool` | `Bool?` | opt | v0.6.0+; Swift encodes only `true`; absent decodes `false` → never selected for media |
| `template_render_ok` | `*bool` | `Bool?` | ptr | 0.6.5+; **explicit `false` survives the wire** and excludes the model from tool requests; absent = no opinion |
| `tool_constraint_template_hash` | `string` | `String?` | opt | binds grammar capability to the loaded template bytes |
| `estimated_memory_gb`, `parameters` | — | `Double`, `UInt64?` | Swift only | encoded by Swift, dropped by Go |

#### `privacy_capabilities`

Go `PrivacyCapabilities` · Swift `PrivacyCapabilities`. Eight required
booleans: `text_backend_inprocess`, `text_proxy_disabled`,
`python_runtime_locked`, `dangerous_modules_blocked`, `sip_enabled`,
`anti_debug_enabled`, `core_dumps_disabled`, `env_scrubbed`.

#### Prefix-cache objects

| Object | Fields |
|---|---|
| `PrefixCacheV2Capability` | Required: `model_id`, `model_aggregate_hash`, `prompt_contract_id`, `block_hash_version` (`string`); `block_size` (`uint32`); `cache_epoch` (`string`); `enabled`, `ready` (`bool`). Optional `ready_boundary_mode` (`string`): absent/empty retains legacy SSD coverage; `checkpoint` permits only explicitly committed input endpoints. Unknown values are rejected; the field is invalid on resident capabilities. `coordinator/registry/cache_capabilities_v2.go`, `validatePrefixCacheCapability` / `validateMemoryPrefixCacheCapabilities` |
| `PrefixCacheModelStatus` | `model_id`; `backend` ∈ {`contiguous`, `paged`, `unknown`}; `replay_strategy` ∈ {`direct`, `frozen_full`, `tail_replay`, `none`, `unknown`}; `state` ∈ {`ready`, `pending`, `disabled`, `error`}; `reason` ∈ {`ready`, `config_disabled`, `weight_hash_unavailable`, `runtime_identity_unavailable`, `unsupported_layout`, `unsupported_backend`, `paged_hybrid_unsupported`, `scan_pending`, `scan_failed`, `disk_unavailable`, `cache_init_failed`}. Enums validated at the coordinator boundary; Swift `PrefixCacheStatusBackend` / `ReplayStrategy` / `State` / `Reason` (`Messages.swift`) |
| `PrefixCacheDonationOutcomeCount` | `outcome` ∈ {`donated`, `below_effective_token_floor`, `no_complete_block`, `lossy_snapshot` (pre-0.8.0 compat), `incomplete_layer_state`, `stage_size_exceeded`, `write_rate_limited`, `write_queue_full`, `already_durable`, `already_queued`, `cache_closed`, `disk_unavailable`, `write_failed`}; `count` (`uint64`, monotonic per process) |
| `PrefixCacheAnchor` | `chain_hash` (lowercase SHA-256 hex), `token_count` (block-aligned `int`) |

### `heartbeat`

Go `HeartbeatMessage` · Swift `ProviderMessage.Heartbeat`. Built by
`buildHeartbeatJSON` (`provider-swift/Sources/ProviderCore/Coordinator/CoordinatorClient+Registration.swift`);
consumed by `Registry.Heartbeat` (`coordinator/registry/heartbeat.go`). The
default cadence is the `heartbeat_interval_secs` row of
[`cli-reference.md` → `provider.toml` keys](../provider/cli-reference.md#providertoml-keys-read-by-the-cli);
the liveness timeout and what happens when heartbeats stop (stale → evicted,
in-flight requests) are owned by
[`scheduling.md` → Heartbeat cadence and eviction](../architecture/scheduling.md#heartbeat-cadence-and-eviction);
the sinks of each field are in [`telemetry-inventory.md`](telemetry-inventory.md).

| JSON key | Go | Swift | Presence | Notes |
|---|---|---|---|---|
| `status` | `string` | `ProviderStatus` | req | `"idle"`, `"serving"` or `"draining"` (`Protocol/Enums.swift`, `ProviderStatus`; Go `HeartbeatStatusDraining`). A draining heartbeat excludes the provider from new routing; idle/serving clears the mark (`coordinator/registry/drain_state.go`, `applyHeartbeatDrainStateLocked`). |
| `active_model` | `*string` (**no** `omitempty`) | `String?` (`encodeIfPresent`) | see note | **Intentional asymmetry.** Go always emits the key and writes `null` when nil; Swift omits the key when nil. Both decode to nil = no model is generating right now, and the coordinator treats `null` and absent identically |
| `stats` | `HeartbeatStats` | `ProviderStats` | req | [`stats`](#stats) |
| `warm_models` | `[]string` | `[String]` | opt | resident models; Swift omits when empty |
| `system_metrics` | `SystemMetrics` | `SystemMetrics` | req | `memory_pressure` (`float64`, 0–1), `cpu_usage` (`float64`, 0–1), `thermal_state` ∈ {`nominal`, `fair`, `serious`, `critical`} |
| `backend_capacity` | `*BackendCapacity` | `BackendCapacity?` | opt | nil on old providers; [`backend_capacity`](#backend_capacity) |
| `prefix_cache_protocol` | `int` | `Int?` | opt | Swift omits nil/0 |
| `prefix_cache_v2_models` | `*[]PrefixCacheV2Capability` | `[…]?` | ptr | omitted (old provider) vs authoritative `[]` (v2 provider clearing its live set) |
| `prefix_cache_memory_models` | `*[]PrefixCacheV2Capability` | `[…]?` | ptr | omitted preserves resident inventory; `[]` clears it; protocol downgrade clears it; `UpdatePrefixCacheSnapshot`, `coordinator/registry/cache_snapshot.go` |
| `prefix_cache_statuses`, `prefix_cache_donation_outcomes` | `*[]…` | `[…]?` | ptr | same pointer rule |
| `apns_device_token`, `apns_environment` | `string` | `String?` | opt | late or rotated APNs token so the coordinator can re-arm a code challenge without a reconnect; the token alone never grants `CodeAttested` |

#### `stats`

Go `HeartbeatStats` · Swift `ProviderStats`. All `int64` in Go, `UInt64` in
Swift; cumulative per provider session and delta-merged by the registry.
`requests_served` and `tokens_generated` are required; the rest are `omitempty`.

| Group | Keys |
|---|---|
| Serving | `requests_served`, `tokens_generated` |
| Cancels and errors | `cancellations_received`, `cancellations_before_output`, `cancellations_partial_complete`, `generation_errors_after_output`, `chunk_encryption_errors`, `stream_closed_without_terminal`, `cancel_during_model_load`, `usage_gaps` |
| Profiler cancel accounting (absent on pre-profiler providers) | `cancel_stage_pre_accept_total`, `cancel_stage_pre_engine_total`, `cancel_stage_prefill_total`, `cancel_stage_decode_total`, `cancel_stage_post_terminal_total`, `tokens_after_cancel_total`, `cancel_abort_ns_sum` |

#### `backend_capacity`

Go `BackendCapacity` · Swift `BackendCapacity` (`Types.swift`). Slot semantics
and how the scheduler reads them: [`../architecture/scheduling.md`](../architecture/scheduling.md).

| JSON key | Go | Swift | Presence | Notes |
|---|---|---|---|---|
| `slots` | `[]BackendSlotCapacity` | `[BackendSlotCapacity]` | req | [`slots[]`](#slots) |
| `gpu_memory_active_gb`, `gpu_memory_peak_gb`, `gpu_memory_cache_gb` | `float64` | `Double` | req | Metal active / peak / reclaimable cache, shared across slots |
| `total_memory_gb` | `float64` | `Double` | req | |
| `free_for_load_gb` | `*float64` | `Double` (always encoded) | ptr | **The single source of truth for cold-load admission**: max additional model-weight GB loadable now, net of the unified-memory cap (`defaultCapFraction`, [`../architecture/hardware-support.md#constants`](../architecture/hardware-support.md#constants)), the OS/operator reserve and activation + minimum-KV headroom, clamped to real OS-available memory, with idle resident models counted as evictable. Nil (legacy provider) → the coordinator falls back to its total-memory heuristic |
| `mlx_cache_reclaimer` | `*MLXCacheReclaimerTelemetry` | `MLXCacheReclaimerTelemetry?` | opt | cumulative allocator-reclaim counters (`uint64`, reset on restart): `cache_limit_bytes`, `sweep_signals`, `reclaims`, `reclaimed_bytes`, `last_reclaimed_bytes`, `last_reclaim_duration_ms` |
| `capacity_seq` | `uint64` | `UInt64` | opt | per-connection monotonic snapshot sequence; the coordinator discards stale or reordered snapshots, and any `seq > 0` marks the connection quote-capable (`capacity_probe`). 0/omitted = legacy last-write-wins |
| `telemetry` | `*CapacityTelemetry` | `CapacityTelemetry?` | opt | [`backend_capacity.telemetry`](#backend_capacitytelemetry) |
| `prefix_cache_maintenance` | `*PrefixCacheMaintenanceTelemetry` | `PrefixCacheMaintenanceTelemetry?` | opt | Process-lifetime whole-root removal counters: `ttl_expired_total`, `budget_evicted_total`, `temp_removed_total`; includes unloaded models, separate from active-store evictions |

#### `slots[]`

Go `BackendSlotCapacity` · Swift `BackendSlotCapacity`. One entry per loaded
model. Every engine-health, `kv_backend` and `telemetry` field is **measurement
only**: the coordinator decodes them into the routing snapshot but does not gate
routing on them.

| JSON key | Go | Swift | Presence | Notes |
|---|---|---|---|---|
| `model` | `string` | `String` | req | |
| `state` | `string` | `String` | req | Coordinator accepts `running`, `idle`, `idle_shutdown`, `crashed`, `reloading`; `registry.SlotStateFold` (`coordinator/registry/gate_reason.go`) folds anything else to `other`. The v0.8.16 provider emits `running`, `idle`, `crashed`, `reloading` (`provider-swift/Sources/ProviderCore/Inference/EngineV2Bridge+Capacity.swift`); `idle_shutdown` stays accepted for older providers. `idle` means the model **is loaded** (`slotStateModelLoaded`, `coordinator/registry/scheduler.go`); `reloading`/`crashed` make the slot unroutable |
| `num_running`, `num_waiting` | `int` | `UInt32` | req | |
| `max_concurrency` | `int` | `UInt32` | opt | |
| `active_tokens` | `int64` | `Int64` | req | Σ (prompt + completion) tokens over running requests |
| `max_tokens_potential` | `int64` | `Int64` | req | Σ `max_tokens` over running requests |
| `observed_decode_tps` | `float64` | `Double` | opt | EWMA of per-request decode TPS |
| `observed_prefill_tps` | `float64` | `Double` | opt | EWMA (admission → first token); omitted when unmeasured |
| `active_token_budget_used`, `active_token_budget_max`, `queued_token_budget` | `int64` | `Int64` | opt | `queued_token_budget` is hard-coded `0` by the v0.8.16 provider (`backendSlotCapacity`, `EngineV2Bridge+Capacity.swift`), so it is always omitted |
| `kv_bytes_per_token` | `int64` | `Int64` | opt | |
| `model_load_time_ms` | `int64` | `Int64` | opt | measured cold load; omitted when unmeasured |
| `kv_backend` | `*string` | `String?` | ptr | resolved KV kind `"paged"` or `"contiguous"`. **Nil = unknown** (pre-0.8.0 provider), never read as `contiguous`; a non-nil `""` still marshals as `"kv_backend":""` |
| `kv_backend_fallback_reason` | `*string` | `String?` | ptr | why the slot is not on the requested backend: `kill_switch`, `"kernel_preflight: …"`, `"physical_capacity: …"`, `"ineligible: …"`, `"pool_construction_capacity: …"`. **Absent = did not degrade** (the opposite rule to `kv_backend`). Untrusted free text; `registry.KVBackendFallbackTag` (`coordinator/registry/kv_backend.go`) folds it to a bounded class before any metric tag |
| `steps_executed`, `admits`, `first_tokens_emitted` | `int64` | `Int64` | opt | cumulative engine-health counters |
| `seconds_since_last_step`, `seconds_since_last_first_token` | `float64` | `Double` | opt | |
| `wedge_suspected` | `bool` | `Bool` | opt | provider-computed: ≥ N consecutive admits, 0 first tokens, ≥ T s |
| `eval_in_flight_ms`, `idle_clear_in_flight_ms` | `int64` | `Int64` | opt | ms the current blocking eval / idle clear has run. `eval_in_flight_ms` comes from `EvalProbe.currentEvalElapsedMs`; `idle_clear_in_flight_ms` is never set by v0.8.16 |
| `telemetry` | `*SlotTelemetry` | `SlotTelemetry?` | opt | [`slots[].telemetry`](#slotstelemetry); **presence is the "profiler-aware provider" sentinel** — omission ≠ empty object |
| `prefix_cache` | `*PrefixCacheTelemetry` | `PrefixCacheTelemetry?` | opt | [Durable cache observation](#slotsprefix_cache); no store or disabled stats tick means absent |
| `paged_storage` | `*PagedStorageTelemetry` | `PagedStorageTelemetry?` | opt | [Paged storage observation](#slotspaged_storage); absent means uninstrumented, never zero ownership |

#### `slots[].prefix_cache`

Optional `PrefixCacheTelemetry` (`coordinator/protocol/prefix_cache_telemetry.go`,
`provider-swift/Sources/ProviderCore/Protocol/PrefixCacheTelemetry.swift`). Absence
means uninstrumented; all numbers are unsigned 64-bit integers. The console
mirror is `PrefixCacheTelemetry` in `console-ui/src/app/providers/types.ts`.
These heartbeat-only additions do not change canonical registration signatures.

| JSON fields | Meaning |
|---|---|
| `kind` | Closed `attention_blocks` or `complete_checkpoint` |
| `generation`, `sample_seq`, `sample_age_ms` | Loaded-cache generation, observation sequence, monotonic observation age; generation/sequence must be positive. Only the stats tick increments `sample_seq`; every capacity refresh advances age |
| `entries`, `disk_bytes`, `staging_bytes` | Current index entries, indexed on-disk bytes, live staging bytes at the observation |
| `stages_total`, `files_written_total`, `written_bytes_total` | Store-lifetime successful stages, writes and bytes; attention writes include sidecars |
| `donation_drops_total`, `corrupt_drops_total`, `evictions_total` | Existing store drop counters and active-store disk-budget removals. For complete checkpoints, `donation_drops_total` is queued-write `writesDropped`; prequeue refusals appear only in the separate donation outcome snapshot, which classifies every exported endpoint attempt |
| `ttl_expired_total` | Optional attention-store TTL removal counter; whole-root TTL maintenance uses the process counters above |
| `io` | Optional complete-store `PrefixCacheIOTelemetry`; absent for attention stores whose read/duration counters are not instrumented |
| `io.staging_peak_bytes` | Peak charged staging reservation over this store's lifetime |
| `io.files_read_total`, `read_bytes_total`, `stage_read_bytes_total`, `donation_read_bytes_total` | Store-lifetime read attempts/bytes, with stage and donor-authentication byte components |
| `io.stage_us_total`, `write_us_total` | Cumulative wall time in microseconds; stage includes refused attempts, write includes donor authentication and maintenance. These are not latency samples |

`clampPrefixCacheTelemetry` (`coordinator/registry/prefix_cache_telemetry.go`)
and `reconcileCapacitySamples` (`coordinator/registry/capacity_sample_freshness.go`)
drop unknown kinds/zero sequence,
cap entries at `1 << 32`, gauge bytes at `1 << 50` and other measurements at
`1 << 60`, and prevent repeated/reordered observations rolling back a live
baseline. Samples older than `capacitySampleFreshMS = 5 * 60 * 1000`
remain visible with age but do not produce current gauges or counter deltas
(`coordinator/api/provider_prefix_cache_telemetry.go`). None of these values
change routing or memory admission.

#### `slots[].paged_storage`

Optional `PagedStorageTelemetry` (`coordinator/protocol/paged_storage_telemetry.go`),
mirrored in `provider-swift/Sources/ProviderCore/Protocol/PagedStorageTelemetry.swift`
and `console-ui/src/app/providers/types.ts`. `PagedStorageTelemetryAdapter` reads
the immutable native queue capture through `EngineV2Bridge.backendSlotCapacity`. The object is observational, outside canonical registration signature
inputs. Older peers can omit or ignore it. All numeric fields are unsigned
64-bit integers; the optional fields distinguish missing instrumentation from
an observed zero.

| JSON fields | Meaning in `PagedStorageTelemetry` |
|---|---|
| `kind` | Closed value `segmented`; other values are dropped |
| `generation`, `sample_seq`, `sample_age_ms` | Pool generation, actual capture sequence, and monotonic capture age in milliseconds. Generation and sequence must be positive; a heartbeat must not create a new capture |
| `grant_bytes`, `committed_bytes` | Pool grant and actual allocated native segment bytes at capture time |
| `reserved_page_bytes`, `live_page_bytes` | Worst-case page bytes promised to admitted requests, window-capped where applicable; pages with live references. These overlap committed ownership and must not be added to it |
| `poison_bytes`, `slack_bytes`, `over_grant_bytes` | Segment guard-page ownership; usable logical slack `max(committed − allocator_padding − poison − reserved_page, 0)`; `max(committed − grant, 0)` |
| `allocator_padding_bytes` | Optional retained allocator bytes beyond logical segment storage. These bytes cannot hold KV pages and are excluded from slack |
| `last_allocation_allowance_bytes` | Optional unused conservative allowance released after the latest successful preparation. This is a last-operation gauge, not retained memory or a cumulative counter |
| `segment_count`, `address_pages` | Segment and logical address-page counts |
| `nominal_kv_bytes`, `physical_floor_overhead_bytes` | Optional Admission nominal KV accounting, including safely detached retiring owners; `max(physical_floor − nominal_kv, 0)`. These overlap other ownership gauges |
| `allocation_failures_total`, `admission_refusals_total` | Optional cumulative native preparation/evaluation failures and preallocation physical-floor ledger refusals, respectively |
| `grant_refusals_total`, `grant_epoch_retries_total` | Optional cumulative grant-policy refusals and discarded preparations after grant-epoch changes |

`PagedKVPool.segmentStorageSnapshot` assigns the pool UUID, sequence and
monotonic capture time. The provider maps pool UUIDs to positive numeric
generations below `1 << 53`; it does not send UUID metric labels. Repeated or
regressed captures retain their values and age from their original capture.
Off-queue grant changes update the separate slot capacity fields immediately
and leave the entire `paged_storage` observation unchanged until a queue capture.
Missing instrumentation is omitted; it does not manufacture zero ownership.

`clampPagedStorageTelemetry` (`coordinator/registry/paged_storage_telemetry.go`)
caps byte gauges at `1 << 50`, segment/address counts at `1 << 32`, and age and
counters at `1 << 60`. `reconcileCapacitySamples` uses the same freshness policy
as prefix-cache observations: repeated or regressed sequences retain the old
sample and advance its age by coordinator elapsed time. Missing samples clear
the baseline; a changed generation seeds a new one. No unbounded pool history
is retained. `reconcileCapacitySamplesLocked` keeps a separate accepted-sample
clock: rejected capacity frames update liveness without resetting sample age.
`recordPagedStorageTelemetry`
(`coordinator/api/provider_paged_storage_telemetry.go`) emits age/freshness even
for repeated samples, but emits ownership gauges and positive counter deltas
only for new samples within the existing five-minute freshness limit. The
first observation, reload, missing optional counter, or decreasing counter
contributes no delta. These values do not affect routing or admission.

#### `slots[].telemetry`

Go `SlotTelemetry` (`coordinator/protocol/profile.go`) · Swift `SlotTelemetry`
(`InferenceProfile.swift`). Every numeric is `*T` + `omitempty` in Go and
optional in Swift; inside a present object an absent numeric reads as 0.
Clamped by `registry.clampBackendCapacity`; persisted to `fleet_snapshots`
([`../architecture/system-profiler.md`](../architecture/system-profiler.md)).

| JSON key | Type | Meaning |
|---|---|---|
| `queued_prefill_tokens` | `int64` | Σ prompt tokens of requests whose engine submit has not returned |
| `partial_prefill_rows` | `int64` | admitted rows with no first token yet |
| `prefill_tokens_total` | `int64` | cumulative |
| `isolated_prefill_tps` | `float64` | isolated prefill EWMA |
| `ewma_initialized` | `bool` | whether `isolated_prefill_tps` has a sample |
| `pump_tasks` | `int64` | live stream-pump tasks |
| `mtp_rounds_total`, `mtp_proposed_total`, `mtp_accepted_total` | `int64` | cumulative MTP counters |
| `kv_bytes_in_use`, `kv_bytes_capacity` | `int64` | raw bytes |
| `eval_in_flight_ms` | `int64` | same read as the slot-level key |
| `step_wall_ns_total`, `decode_rows_total` | `int64` | cumulative engine counters (slice 3) |

#### `backend_capacity.telemetry`

Go `CapacityTelemetry` · Swift `CapacityTelemetry`. Same presence rules as
`slots[].telemetry`.

| JSON key | Type | Meaning |
|---|---|---|
| `low_power_mode` | `*bool` | `ProcessInfo.isLowPowerModeEnabled` |
| `memory_pressure_level` | `MemoryPressureLevel` ∈ {`normal`, `warning`, `critical`, `other`}; `""` = absent | last kernel memory-pressure level |
| `mlx_num_resources` | `*int64` | live MLX buffers |
| `in_admission` | `*int64` | requests accepted but not finished |
| `inflight_tasks` | `*int64` | detached inference tasks |
| `process_memory` | `*ProcessMemoryTelemetry` | Optional coherent process admission observation; absence differs from measured zero |

#### `backend_capacity.telemetry.process_memory`

Go `ProcessMemoryTelemetry` (`coordinator/protocol/process_memory_telemetry.go`)
and the Swift/TypeScript mirrors report the same scalar snapshot. This object
is diagnostic and does not authorize admission, routing, or prefix reuse.

| JSON keys | Type | Meaning |
|---|---|---|
| `generation`, `sample_seq` | `uint64` | Nonzero JavaScript-exact producer identity and actual capture sequence |
| `sample_age_ms` | `uint64` | Elapsed monotonic age; another heartbeat preserves the capture sequence |
| `policy_epoch` | `uint64` | Process ledger policy revision at capture |
| `cap_bytes`, `activation_reserve_bytes` | `uint64` | Capacity policy and activation allowance |
| `active_bytes`, `cache_bytes` | `uint64` | One coherent MLX allocator observation; their sum is U |
| `charged_bytes`, `materialized_bytes`, `unmaterialized_bytes` | `uint64` | C, covered backing M, and C−M; admission projects U+(C−M) |
| `remaining_bytes`, `commitment_debt_bytes` | `uint64` | Available runtime capacity or existing commitment debt under that policy |
| `owner_count`, `closing_owner_count` | `uint64` | Live ledger owners and the subset retiring existing resources |
| `system_available_bytes` | `*uint64` | Optional OS free-memory observation; omitted when unavailable |

`validProcessMemoryTelemetry` (`coordinator/registry/process_memory_telemetry.go`)
discards inconsistent ownership identities and oversized samples instead of
clamping C and M independently. `reconcileCapacitySamples`
(`coordinator/registry/capacity_sample_freshness.go`) retains and ages repeated
or regressed samples within a generation, including providers with no loaded
slots. Only accepted capacity replacements advance the reconciliation clock.
New fresh captures emit gauges; repeated or stale captures emit only age and
freshness (`coordinator/api/provider_process_memory_telemetry.go`,
`recordProcessMemoryTelemetry`).

### `inference_accepted`

Go `InferenceAcceptedMessage` · Swift `InferenceAccepted`. `request_id`
(`string`, req). The provider accepted the request (it may still be reloading);
the coordinator extends the wait window to the full inference timeout but may
still retry before the first chunk.

### `inference_response_chunk`

Go `InferenceResponseChunkMessage` · Swift `InferenceResponseChunk`.

| JSON key | Go | Swift | Presence | Notes |
|---|---|---|---|---|
| `request_id` | `string` | `String` | req | |
| `data` | `string` | `String` | opt | SSE chunk text; empty when E2E encryption is active |
| `encrypted_data` | `*EncryptedPayload` | `EncryptedPayload?` | opt | [`EncryptedPayload`](#encryptedpayload) |

### `inference_complete`

Go `InferenceCompleteMessage` · Swift `InferenceComplete`.

| JSON key | Go | Swift | Presence | Notes |
|---|---|---|---|---|
| `request_id` | `string` | `String` | req | |
| `usage` | `UsageInfo` | `UsageInfo` | req | [`UsageInfo`](#usageinfo) |
| `stop_sequence` | `string` | `String?` | opt | exact caller stop string matched |
| `se_signature` | `string` | `String?` | opt | Secure Enclave signature over `response_hash` |
| `response_hash` | `string` | `String?` | opt | SHA-256 of the response data |
| `profile` | `json.RawMessage` | `InferenceProfile?` (encoded via `saturatedToWireRanges()`) | opt | the system-profiler per-attempt object. Go keeps the **raw bytes**: the WS read loop only length-checks it (`MaxInferenceProfileBytes = 4096`) so a malformed profile can never fail the terminal decode; the typed decode runs on the profile-sink worker (`coordinator/api/profiler_provider.go`). Observability only. Field list and validation: [`../architecture/system-profiler.md`](../architecture/system-profiler.md) |

### `inference_error`

Go `InferenceErrorMessage` · Swift `InferenceError`. Outcome classification of
these fields: [`../architecture/request-outcome-observability.md`](../architecture/request-outcome-observability.md).

| JSON key | Go | Swift | Presence | Notes |
|---|---|---|---|---|
| `request_id` | `string` | `String` | req | |
| `error` | `string` | computed `String` (`failureCode.message`) | req | Swift never emits raw error text. The coordinator never reads the provider-authored value: `sanitizeProviderInferenceError` (`coordinator/api/inference_error_sanitize.go`) replaces it with the closed message for `failure_code` before anything downstream sees the frame |
| `status_code` | `int` | `UInt16` | req | |
| `error_reason` | `string` | `InferenceErrorReason?` | opt | closed, privacy-safe reason (`provider-swift/Sources/ProviderCore/Inference/InferenceFailure.swift`): `jinja_channel_tags`, `jinja_null_bridge`, `jinja_template`, `model_load`, `capacity_timeout`, `queue_full`, `token_budget_exhausted`, `request_exceeds_context`, `request_exceeds_node`, `request_exceeds_node_budget`, `request_exceeds_batch_token_budget`, `capacity_busy`, `deadline_unreachable`, `draining`, `cancelled`, `client_error`, `tool_noncompliance`. The typed `draining` reason on a 503 marks a transient update drain: no provider-health or capacity penalty, and no capacity retry charge (`coordinator/api/consumer.go`, `noteInferenceError`; `coordinator/api/dispatch.go`, `dispatchState.noteProviderError`). Swift emits it from `rejectIfDrainingForUpdate` (`provider-swift/Sources/ProviderCore/ProviderLoop+InferenceHandler.swift`). |
| `failure_code` | `InferenceFailureCode` | `InferenceFailureCode?` | opt | closed enum (`coordinator/protocol/inference_failure.go`): `invalid_request`, `invalid_media`, `media_too_large`, `unsupported_media`, `template_render`, `model_unavailable`, `capacity`, `cancelled`, `encryption_failure`, `generation_failure`, `internal_failure` |
| `terminal_cause` | `string` | `InferenceTerminalCause?` | opt | closed: `admission_timeout`, `prefill_stall`, `decode_stall`, `safety_deadline`, `backpressure_timeout`, `watchdog`, `cancelled`, `engine_error`. Unknown → treated as absent plus a drift metric (`coordinator/api/terminal_cause.go`); platform-policy terminals never strike health breakers |
| `attempt_usage` | `*UsageInfo` | `UsageInfo?` | opt | engine-reconciled usage of the failed attempt; observability only, never billing |
| `rejection_reason` | `CapacityRejectionReason` | `CapacityRejectionReason?` | opt | routing-v2 enriched rejection; enum shared with [`capacity_quote`](#capacity_quote) |
| `available_token_budget` | `*int64` | `Int64?` | ptr | **an explicit zero is encoded** (busy slot, zero free tokens); nil/absent = legacy frame |
| `feasible_after_ms` | `int64` | `Int64?` | opt | duration forecast, never a wall clock; Swift omits 0 |
| `capacity_seq` | `uint64` | `UInt64?` | opt | the snapshot the gate decided from; Swift omits 0 |
| `profile` | `json.RawMessage` | `InferenceProfile?` | opt | same contract as `inference_complete`; the sanitizer passes it through as opaque bytes |
| — (`CoordinatorCause`) | `json:"-"` | — | never on the wire | coordinator-synthetic only (`provider_disconnected`) |

### `attestation_response`

Go `AttestationResponseMessage` · Swift `AttestationResponse`. Reply to
[`attestation_challenge`](#attestation_challenge).

| JSON key | Go | Swift | Presence | Notes |
|---|---|---|---|---|
| `nonce` | `string` | `String` | req | echoed |
| `signature` | `string` | `String` | req | base64 SE signature over nonce + timestamp (liveness) |
| `status_signature` | `string` | `String?` | opt | v0.3.11+; signature over the canonical JSON of nonce + timestamp + all status fields (`attestation.BuildStatusCanonical`, `coordinator/attestation/`); absent ⇒ status fields are advisory only |
| `public_key` | `string` | `String` | req | base64 |
| `hypervisor_active` | `*bool` | — | legacy | `< v0.6.31` providers only; Swift omits it; Go keeps decoding it so their status signature verifies |
| `rdma_disabled`, `sip_enabled`, `secure_boot_enabled` | `*bool` | `Bool?` | opt | fresh posture at challenge time |
| `binary_hash`, `active_model_hash`, `python_hash`, `runtime_hash` | `string` | `String?` | opt | SHA-256 |
| `template_hashes`, `model_hashes` | `map[string]string` | `[String: String]` | opt | Swift omits when empty |

### `code_attestation_response`

Go `CodeAttestationResponseMessage` · Swift `CodeAttestationResponse`. `nonce`
(decrypted pushed nonce, base64) and `signature` (SE P-256 signature over the
nonce bytes), both required. Verified against the SE key bound at registration,
never a key carried in this message.

### `load_model_status`

Go `LoadModelStatusMessage` · Swift `LoadModelStatus`. `model_id` (req);
`status` ∈ {`started`, `succeeded`, `failed`} (`LoadModelStatus*` constants,
req); `error` (`string`, opt). `"provider draining for update"` in `error` is
matched as a transient failure.

### `prefetch_model_status`

Go `PrefetchModelStatusMessage` · Swift `PrefetchModelStatus`. `model_id`
(req); `status` ∈ {`started`, `downloading`, `verified`, `failed`} — `verified`
is the terminal success: on disk, hash-checked, **not** loaded; `bytes_done`,
`bytes_total` (`int64`, opt; Swift omits 0); `error` (opt).

### `models_update`

Go `ModelsUpdateMessage` · Swift `ModelsUpdate`. `models` (`[]ModelInfo`, same
encoding as `register`); `tool_constraint_protocol` (`int`, opt);
`tool_constraint_models` (`[]string`, opt). The coordinator cross-checks each
`weight_hash` against the catalog before merging, so a verified build becomes
routable without a re-register.

### `prefix_cache_lookup`

Go `PrefixCacheLookupMessage` · Swift `PrefixCacheLookup`.

| JSON key | Go | Swift | Presence |
|---|---|---|---|
| `request_id`, `cache_receipt_nonce` | `string` | `String` | req |
| `outcome` | `string` | `PrefixCacheLookupOutcome` (`hit`, `miss_absent`, `miss_corrupt`, `skipped_capacity`, `skipped_cost`, `skipped_policy`) | req |
| `tier` | `string` | `PrefixCacheTier?` (`memory`, `ssd`) | opt |
| `cached_tokens`, `prefill_tokens_saved` | `int` | `UInt64?` | opt |
| `stage_ms` | `float64` | `Double?` | opt |

### `prefix_cache_ready`

Go `PrefixCacheReadyMessage` · Swift `PrefixCacheReady`. May arrive after
`inference_complete`.

| JSON key | Go | Swift | Presence |
|---|---|---|---|
| `request_id`, `cache_receipt_nonce` | `string` | `String` | req |
| `ready_tokens` | `int` | `UInt64` | req |
| `required_recompute_tokens`, `expected_prefill_tokens_saved` | `int` | `UInt64` (always encoded) | opt in Go |
| `tier` | `string` | `PrefixCacheTier` (always encoded) | opt in Go |
| `stage_ms` | `float64` | `Double` | opt; Swift clamps to `[0, PrefixCacheReadyResult.maxStageMs]` |

### `prefix_cache_lookup_v2`

Go `PrefixCacheLookupV2Message` · Swift `PrefixCacheLookupV2`. Accepted only
for `tier = ssd` or `memory` with that tier's separately advertised capability.
Both require the exact nonce-bound prompt proof; memory cannot borrow an SSD
lookup or sequence. Acceptance: `applyLookupV2Result`,
`coordinator/registry/cache_receipts_v2.go`.

| JSON key | Go | Presence |
|---|---|---|
| `request_id`, `cache_receipt_nonce`, `model_id`, `model_aggregate_hash`, `prompt_contract_id`, `cache_epoch` | `string` | req |
| `cache_seq` | `uint64` | req |
| `prompt_anchor` | `PrefixCacheAnchor` | req |
| `matched_anchor` | `*PrefixCacheAnchor` | opt |
| `outcome` | `string` | req |
| `tier` | `string` | opt |
| `required_recompute_tokens`, `expected_prefill_tokens_saved` | `int` | opt |
| `stage_ms` | `float64` | opt |

### `prefix_cache_ready_v2`

Go `PrefixCacheReadyV2Message` · Swift `PrefixCacheReadyV2`. SSD requires durable
settlement. Without `ready_boundary_mode`, the first SSD anchor must be the
input-prompt floor. With `ready_boundary_mode=checkpoint`, only supplied committed
input checkpoints are accepted, with zero recompute and positive `stage_ms`.
Memory requires a published resident checkpoint and its own live
capability. Every explicit checkpoint must match an input boundary in the nonce-bound
coordinator plan; a shorter actual checkpoint is valid even when the longest
prompt boundary is not reusable. Acceptance: `applyReadyV2Result`,
`coordinator/registry/cache_receipts_v2.go`.

For a complete-checkpoint slot, a pre-v2 coordinator's legacy attempt is settled
with `skipped_policy`; no count-only HIT/READY is emitted. Protocol v2 without
the matching echo emits no checkpoint receipt. Local cache reuse and normal
inference responses continue in both cases (`ProviderLoop+InferenceHandler.swift`,
`PrefixCacheReceiptEmitter.suppressLegacyCheckpointReceipts`,
`PrefixCacheEvidenceSequencer.callbacks`).

| JSON key | Go | Presence |
|---|---|---|
| `request_id`, `cache_receipt_nonce`, `model_id`, `model_aggregate_hash`, `prompt_contract_id`, `cache_epoch` | `string` | req |
| `cache_seq` | `uint64` | req |
| `outcome` | `string` | req (Swift default `"ready"`) |
| `tier` | `string` | req |
| `ready_anchors` | `[]PrefixCacheAnchor` | req; legacy SSD caps at 2 (prompt + continuation); checkpoint-mode SSD and memory cap at 16 actual input checkpoints |
| `required_recompute_tokens`, `expected_prefill_tokens_saved` | `int` | opt |
| `stage_ms` | `float64` | opt |

Memory holder lifetime is `min(configured TTL, 30s)` (`receiptTTL`,
`coordinator/registry/cache_tiers.go`). `stage_ms = 0` means no external disk
staging for resident KV. Sequences increase independently per tier/model/epoch;
nonce, connection, model/hash/contract, epoch, order, and replay checks still
apply. Repeated ready anchors cannot refresh expired evidence. Resident LRU
removal uses bounded TTL and exact-miss invalidation; there is no per-anchor
eviction frame. Unload/reconnect replaces the capability snapshot.

### `capacity_quote`

Go `CapacityQuoteMessage` (`coordinator/protocol/capacity.go`) · Swift
`CapacityQuote`. Answer to one [`capacity_probe`](#capacity_probe). Quotes are
drift correction for the coordinator's ledger, not reservations.

| JSON key | Go | Presence | Notes |
|---|---|---|---|
| `quote_id` | `string` | req | echo of the probe's random, request-local id |
| `capacity_seq` | `uint64` | req | snapshot the quote was computed from; the coordinator trusts the probe window (`capacityProbeWindow`, [`../architecture/routing.md#entry-points`](../architecture/routing.md#entry-points)) and does not compare seqs |
| `admissible_now` | `bool` | req | advisory — the inference request itself is the reservation |
| `rejection_reason` | `CapacityRejectionReason` | opt | present **exactly when** `admissible_now` is false: `token_budget`, `kv_headroom`, `memory_cap`, `slot_state`, `template`, `capability`, `deadline` |
| `ttft_p50_ms`, `ttft_p90_ms` | `float64` | req | end-to-end quantiles from completed comparable requests, never summed per-stage p95s |
| `queue_est_ms` | `float64` | req | |
| `available_token_budget` | `int64` | req | |
| `confidence` | `string` | req | `high` or `low` (`CapacityConfidenceHigh`/`Low`) |

## Coordinator → provider

### `inference_request`

Go `InferenceRequestMessage` · Swift `CoordinatorMessage.InferenceRequest`.

| JSON key | Go | Swift | Presence | Notes |
|---|---|---|---|---|
| `request_id` | `string` | `String` | req | attempt UUID |
| `body` | `InferenceRequestBody` | `JSONValue` | opt | plain body: `model`, `messages[]{role, content}`, `stream` (`bool`), `max_tokens` (`*int`, opt), `temperature` (`*float64`, opt), `endpoint` (`string`, opt; defaults to `/v1/chat/completions`). Empty when `encrypted_body` is set |
| `encrypted_body` | `*EncryptedPayload` | `EncryptedPayload?` | opt | NaCl box; set whenever the provider registered a `public_key` |
| `first_content_budget_ms` | `int64` | `Int64?` | opt | positive time left for this attempt to produce its first content chunk; 0 omitted |
| `cache_receipt_nonce` | `string` | `String?` | opt | binds the prefix-cache receipts to this attempt |
| `cache_scope` | `string` | `String?` | opt | |
| `prefix_cache_protocol` | `int` | `Int?` | opt | |
| `cache_receipt_boundary_mode` | `string` | `String?` | opt | `checkpoint` echoes support for the selected SSD capability. A provider emits checkpoint-mode receipts only with this echo; an older coordinator omits it and remains cold for this format. Copied from the prepared attempt and cleared on retry/fallback; `coordinator/api/provider_wire.go`, `snapshotProviderInferenceFrame` / `wireMessage`; `coordinator/registry/cache_receipts.go`, `ForgetCacheAttempt` |
| `tool_schema_metadata_protocol` | `int` | `Int?` | opt | `1` = the coordinator rejected client-forged reserved keys before normalisation |

### `cancel`

Go `CancelMessage` · Swift `Cancel`. `request_id` (req). Sent on the strict
control lane.

### `attestation_challenge`

Go `AttestationChallengeMessage` · Swift `AttestationChallenge`. `nonce`
(base64, 32 random bytes) and `timestamp` (ISO 8601), both required.

### `code_attestation_resume_challenge`

Go `CodeAttestationResumeChallenge` · Swift `CodeAttestationResumeChallenge`.
`code_challenge` (`EncryptedPayload`, req). Proves possession of the cached
registration X25519 key over the live WebSocket without spending an APNs push.

### `runtime_status`

Go `RuntimeStatusMessage` · Swift `RuntimeStatus`. `verified` (`bool`, req);
`mismatches` (`[]RuntimeMismatch{component, expected, got}`, opt in Go, always
encoded by Swift as `[RuntimeMismatch]`). For a `template:<name>` component
`expected` reads `one of <hash>,<hash>` — every hash the
[runtime manifest](../architecture/security/attestation.md#runtime-manifest)
accepts for that name.

### `load_model`

Go `LoadModelMessage` · Swift `LoadModel`. `model_id` (req). Sent only to
`backend == "mlx-swift"`; the provider replies with `load_model_status`.

### `prefetch_model`

Go `PrefetchModelMessage` · Swift `PrefetchModel`. `model_id` (req); `priority`
(`int`, opt, advisory). Download + verify only, no GPU load; the provider
replies with `prefetch_model_status` and then `models_update`.

### `desired_models`

Go `DesiredModelsMessage` · Swift `DesiredModels`. `models` (`[]DesiredModelEntry`):
`model_name` (public alias), `desired_build` (concrete build id),
`previous_build` (opt; still acceptable mid-rollout). Sent once right after
`register` and again whenever a desired build changes. The provider reconciles:
background-prefetch any missing desired build, hard-swap, emit `models_update`.

### `trust_status`

Go `TrustStatusMessage` · Swift `TrustStatus`. `trust_level` ∈ {`none`,
`self_signed`, `hardware`}; `status` (`online`, `untrusted`, …); `reason`
(opt in Go, `String` in Swift). Operator diagnostics only.

### `capacity_probe`

Go `CapacityProbeMessage` (`coordinator/protocol/capacity.go`) · Swift
`CapacityProbe`. Sent on the bounded data lane to shortlist candidates in
parallel with the primary dispatch. Carries request **shape** only; the field
set is pinned by `TestCapacityProbeShapeClosed` (`coordinator/protocol/capacity_test.go`).

| JSON key | Go | Presence | Notes |
|---|---|---|---|
| `quote_id` | `string` | req | random, request-local; never the request id |
| `model` | `string` | req | |
| `prompt_tokens_bucket` | `int` | req | prompt estimate rounded **up** to a multiple of `CapacityProbePromptBucketTokens = 512` |
| `max_output_tokens` | `int` | req | |
| `requires_vision` | `bool` | opt | |
| `vision_image_count` | `int` | opt | count only |
| `deadline_remaining_ms` | `int64` | req | duration on the first-content clock, never a wall clock |

## Shared objects

### `EncryptedPayload`

Go `EncryptedPayload` · Swift `EncryptedPayload`. `ephemeral_public_key`
(base64 X25519) and `ciphertext` (base64 `nonce || box`), both required.

### `UsageInfo`

Go `UsageInfo` · Swift `UsageInfo`.

| JSON key | Go | Swift | Presence |
|---|---|---|---|
| `prompt_tokens`, `completion_tokens` | `int` | `UInt64` | req |
| `reasoning_tokens` | `int` | `UInt64` | opt; subset of `completion_tokens` |
| `cache_outcome` | `string` | `PrefixCacheLookupOutcome?` | opt |
| `cache_tier` | `string` | `PrefixCacheTier?` | opt |
| `cached_tokens`, `prefill_tokens_saved` | `int` | `UInt64?` | opt |
| `cache_stage_ms` | `float64` | `Double?` | opt — the one provider-side duration outside `profile` |

## Model unloading (no message)

The coordinator never tells a provider to unload. Residency changes reach a
provider only as a `desired_models` reconciliation (prefetch → hard-swap →
`models_update`) and through the provider's own idle timeout
(`provider-swift/Sources/ProviderCore/ProviderLoop+IdleTimeout.swift`;
`idle_timeout_mins` in `provider-swift/Sources/ProviderCore/Config/ProviderConfig.swift`;
default in [`../provider/cli-reference.md#providertoml-keys-read-by-the-cli`](../provider/cli-reference.md#providertoml-keys-read-by-the-cli),
`0` disables). The coordinator observes the result on the next heartbeat
(`warm_models`, `slots[]`); its assumption about that idle-unload cycle is a
comment in `coordinator/registry/capacity_cooldown.go`.

## Tests that pin the wire

| Layer | Files |
|---|---|
| Go shape and envelope | `coordinator/protocol/messages_register_heartbeat_test.go`, `messages_backend_capacity_test.go`, `messages_inference_test.go`, `messages_terminal_cause_test.go`, `messages_attestation_test.go`, `messages_model_lifecycle_test.go`, `messages_envelope_test.go`, `prefix_cache_v2_test.go`, `prefix_cache_telemetry_test.go`, `capacity_test.go`, `inference_failure_test.go`, `tool_constraints_test.go`, `type_scan_test.go` |
| Go ↔ Swift key pinning | `coordinator/api/provider_wire_test.go`; `provider-swift/Tests/ProviderCoreTests/ProtocolTests.swift`, `CapacityQuoteProtocolTests.swift` |
| `profile` fixture | `coordinator/protocol/testdata/profiler_wire_fixture.json` — written by Go, loaded by Swift |

## Related

- [`../architecture/scheduling.md`](../architecture/scheduling.md) — how slot state and budgets drive admission
- [`../architecture/routing.md`](../architecture/routing.md) — gate reasons and candidate selection
- [`../architecture/system-profiler.md`](../architecture/system-profiler.md) — the `profile` object, `request_profiles`, `fleet_snapshots`
- [`../architecture/telemetry.md`](../architecture/telemetry.md) — what the coordinator does with heartbeat data
- [`telemetry-inventory.md`](telemetry-inventory.md) — producer, sink and cadence of every datum
- [`api-contracts.md#headers`](api-contracts.md#headers) — the `X-Timing` header
