# Provider ↔ coordinator protocol messages

> Last updated: 2026-09-03 · commit `5d400cf75`

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
| Decode | `ProviderMessage.UnmarshalJSON` (`coordinator/protocol/messages.go`) reads `type` with `scanTopLevelString` (`coordinator/protocol/type_scan.go`), a byte walk over the top-level keys, then `json.Unmarshal`s the frame **once** into the concrete struct | `ProviderMessage.init(from:)` / `CoordinatorMessage.init(from:)` decode `TypeValue` then switch (`Messages.swift`) |
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
| `PrefixCacheV2Capability` | `model_id`, `model_aggregate_hash`, `prompt_contract_id`, `block_hash_version` (`string`); `block_size` (`uint32`); `cache_epoch` (`string`); `enabled`, `ready` (`bool`). All required |
| `PrefixCacheModelStatus` | `model_id`; `backend` ∈ {`contiguous`, `paged`, `unknown`}; `replay_strategy` ∈ {`direct`, `frozen_full`, `tail_replay`, `none`, `unknown`}; `state` ∈ {`ready`, `pending`, `disabled`, `error`}; `reason` ∈ {`ready`, `config_disabled`, `weight_hash_unavailable`, `runtime_identity_unavailable`, `unsupported_layout`, `unsupported_backend`, `paged_hybrid_unsupported`, `scan_pending`, `scan_failed`, `disk_unavailable`, `cache_init_failed`}. Enums validated at the coordinator boundary; Swift `PrefixCacheStatusBackend` / `ReplayStrategy` / `State` / `Reason` (`Messages.swift`) |
| `PrefixCacheDonationOutcomeCount` | `outcome` ∈ {`donated`, `below_effective_token_floor`, `no_complete_block`, `lossy_snapshot` (pre-0.8.0 compat), `incomplete_layer_state`, `stage_size_exceeded`, `write_rate_limited`, `write_queue_full`, `already_durable`, `already_queued`, `cache_closed`, `disk_unavailable`, `write_failed`}; `count` (`uint64`, monotonic per process) |
| `PrefixCacheAnchor` | `chain_hash` (lowercase SHA-256 hex), `token_count` (block-aligned `int`) |

### `heartbeat`

Go `HeartbeatMessage` · Swift `ProviderMessage.Heartbeat`. Built by
`buildHeartbeatJSON` (`provider-swift/Sources/ProviderCore/Coordinator/CoordinatorClient+Registration.swift`);
consumed by `Registry.Heartbeat` (`coordinator/registry/registry.go`). Cadence
and sinks: [`telemetry-inventory.md`](telemetry-inventory.md).

| JSON key | Go | Swift | Presence | Notes |
|---|---|---|---|---|
| `status` | `string` | `ProviderStatus` | req | `"idle"` or `"serving"` (`Protocol/Enums.swift`) |
| `active_model` | `*string` (**no** `omitempty`) | `String?` (`encodeIfPresent`) | see note | **Intentional asymmetry.** Go always emits the key and writes `null` when nil; Swift omits the key when nil. Both decode to nil = no model is generating right now, and the coordinator treats `null` and absent identically |
| `stats` | `HeartbeatStats` | `ProviderStats` | req | [`stats`](#stats) |
| `warm_models` | `[]string` | `[String]` | opt | resident models; Swift omits when empty |
| `system_metrics` | `SystemMetrics` | `SystemMetrics` | req | `memory_pressure` (`float64`, 0–1), `cpu_usage` (`float64`, 0–1), `thermal_state` ∈ {`nominal`, `fair`, `serious`, `critical`} |
| `backend_capacity` | `*BackendCapacity` | `BackendCapacity?` | opt | nil on old providers; [`backend_capacity`](#backend_capacity) |
| `prefix_cache_protocol` | `int` | `Int?` | opt | Swift omits nil/0 |
| `prefix_cache_v2_models` | `*[]PrefixCacheV2Capability` | `[…]?` | ptr | omitted (old provider) vs authoritative `[]` (v2 provider clearing its live set) |
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
| `free_for_load_gb` | `*float64` | `Double` (always encoded) | ptr | **The single source of truth for cold-load admission**: max additional model-weight GB loadable now, net of the 90 % unified-memory cap, the OS/operator reserve and activation + minimum-KV headroom, clamped to real OS-available memory, with idle resident models counted as evictable. Nil (legacy provider) → the coordinator falls back to its total-memory heuristic |
| `mlx_cache_reclaimer` | `*MLXCacheReclaimerTelemetry` | `MLXCacheReclaimerTelemetry?` | opt | cumulative allocator-reclaim counters (`uint64`, reset on restart): `cache_limit_bytes`, `sweep_signals`, `reclaims`, `reclaimed_bytes`, `last_reclaimed_bytes`, `last_reclaim_duration_ms` |
| `capacity_seq` | `uint64` | `UInt64` | opt | per-connection monotonic snapshot sequence; the coordinator discards stale or reordered snapshots, and any `seq > 0` marks the connection quote-capable (`capacity_probe`). 0/omitted = legacy last-write-wins |
| `telemetry` | `*CapacityTelemetry` | `CapacityTelemetry?` | opt | [`backend_capacity.telemetry`](#backend_capacitytelemetry) |

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
| `error_reason` | `string` | `InferenceErrorReason?` | opt | closed, privacy-safe reason (`provider-swift/Sources/ProviderCore/Inference/InferenceFailure.swift`): `jinja_channel_tags`, `jinja_null_bridge`, `jinja_template`, `model_load`, `capacity_timeout`, `queue_full`, `token_budget_exhausted`, `request_exceeds_context`, `request_exceeds_node`, `request_exceeds_node_budget`, `request_exceeds_batch_token_budget`, `capacity_busy`, `deadline_unreachable`, `cancelled`, `client_error`, `tool_noncompliance`. The well-known string `"provider draining for update"` (`ProviderDrainingForUpdate`) marks a transient drain and earns a short backoff |
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

Go `PrefixCacheLookupV2Message` · Swift `PrefixCacheLookupV2`.

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

Go `PrefixCacheReadyV2Message` · Swift `PrefixCacheReadyV2`. Emitted only after
durable SSD settlement.

| JSON key | Go | Presence |
|---|---|---|
| `request_id`, `cache_receipt_nonce`, `model_id`, `model_aggregate_hash`, `prompt_contract_id`, `cache_epoch` | `string` | req |
| `cache_seq` | `uint64` | req |
| `outcome` | `string` | req (Swift default `"ready"`) |
| `tier` | `string` | req |
| `ready_anchors` | `[]PrefixCacheAnchor` | req; Swift caps at 2 (prompt anchor + final continuation) |
| `required_recompute_tokens`, `expected_prefill_tokens_saved` | `int` | opt |
| `stage_ms` | `float64` | opt |

### `capacity_quote`

Go `CapacityQuoteMessage` (`coordinator/protocol/capacity.go`) · Swift
`CapacityQuote`. Answer to one [`capacity_probe`](#capacity_probe). Quotes are
drift correction for the coordinator's ledger, not reservations.

| JSON key | Go | Presence | Notes |
|---|---|---|---|
| `quote_id` | `string` | req | echo of the probe's random, request-local id |
| `capacity_seq` | `uint64` | req | snapshot the quote was computed from; the coordinator trusts the 250 ms probe window and does not compare seqs |
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
encoded by Swift as `[RuntimeMismatch]`).

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
`idle_timeout_mins` in `provider-swift/Sources/ProviderCore/Config/ProviderConfig.swift`,
default `60`, `0` disables). The coordinator observes the result on the next
heartbeat (`warm_models`, `slots[]`); its 1 h idle-unload assumption lives in
`coordinator/registry/capacity_cooldown.go`.

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
