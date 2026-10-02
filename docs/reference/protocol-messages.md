# Provider ↔ coordinator protocol messages

> Last updated: 2026-10-02

Every JSON frame on the provider WebSocket (`GET /ws/provider`), with the Go
type, the Swift type, and the presence rule for each field. Go is the canon
(`coordinator/protocol/messages.go`, `capacity.go`, `profile.go`, `model_autopilot.go`); Swift mirrors
it (`provider-swift/Sources/ProviderCore/Protocol/Messages.swift`, `Types.swift`,
`InferenceProfile.swift`, `Autopilot/ModelAutopilot.swift`). The message inventory and additive lifecycle/attestation sections enumerate the accepted types.

Conventions: **req** = always present; **opt** = Go `omitempty`, Swift
`encodeIfPresent` (absent when nil, and for scalars when zero/empty unless a
row says otherwise); **ptr** = Go pointer with `omitempty`, so absent ≠ zero.
JSON keys are snake_case and identical in the Go tags and the Swift
`CodingKeys`.

Terminal `profile` objects can include optional schema-1
[`deadline_decision`](prediction-decision-telemetry.md#provider-fields).
Its optional `unbounded_reason` identifies the first engine guard family that
prevented an admissible projection; older profiles keep the cause absent.
This does not add a message type or change the public error code.

The additive [App Attest shadow exchange](app-attest-shadow.md#wire-exchange) uses `register.app_attest_protocol = 3` and `app_attest_shadow` frames; the coordinator serves protocol 3 only, and a registration announcing protocol 1 or 2 gets no frames. Protocol 3 binds the account, status, static hardware and the existing verification key. Shadow alone does not replace authoritative verification. The separately enabled [provider authorization](provider-authorization.md) path consumes qualified protocol 3 evidence and adds coordinator-derived `trust_status.authorization` diagnostics; legacy message meanings remain unchanged.

App Attest error replies optionally carry `apple_error: {domain, code, underlying_domain?, underlying_code?}`. Domain buckets and signed 32-bit bounds are defined by `coordinator/protocol/app_attest_error.go` (`AppAttestAppleError.Valid`) and mirrored in `provider-swift/Sources/ProviderAppAttest/AppAttestAppleError.swift`. Failed `ready` replies may also carry closed `availability_reason`; synthetic `apple_error` replies may carry closed `apple_error_source`. `coordinator/protocol/app_attest_client_diagnostic.go` (`ValidClientDiagnostics`) bounds both fields. `ready` replies may also carry optional `launch_session`, `boot_time` and `operation_stalled_seconds`; `coordinator/protocol/app_attest_runtime_diagnostic.go` (`SanitizeRuntimeDiagnostics`) strips invalid values without rejecting the frame. These untrusted diagnostics are excluded from the signed transcript and cannot authorize serving; missing fields preserve older peers. See [wire details](app-attest-shadow.md#wire-exchange).

`ready` replies may also carry optional deep diagnostics (`process_started_at`, `previous_exit`, `start_reason`, `console_user_active`, `sip_enabled`, `authenticated_root`, `preflight`, `key_history`, `push_history`), and failed `attestation`/`assertion` replies with result `apple_error` or `apple_invalid_key` may carry `native_error_chain`; `coordinator/protocol/app_attest_deep_diagnostic.go` strips each invalid or misplaced member without rejecting the frame. See [Provider diagnostics](app-attest-shadow.md#provider-diagnostics).

## Provider lifecycle drain

| Direction | Type | Required fields | Behavior / source |
|---|---|---|---|
| Provider → coordinator | `provider_drain` | `request_id`: nonempty random barrier ID, at most 64 bytes | `coordinator/protocol/provider_drain.go` (`ProviderDrainMessage`), Swift `ProviderMessage.drainBarrier` |
| Coordinator → provider | `provider_drain_ack` | Matching `request_id` | Swift `CoordinatorMessage.drainAck`; only the issuing connection's current waiter can consume it |

The registered provider closes admission first, then sends a barrier over the
FIFO control writer. The coordinator fences that connection from new dispatch
and asynchronously waits for held/queued inference reservations to be removed,
then for completion/billing workers to settle. Pending removal signals an event;
there is no polling and ordinary serving allocates no reservation-wait tracking.
Billing begun during reservation cleanup or settlement is included before the
receipt. Heartbeat/challenge reads continue during that wait. Each connection
has one acknowledgement worker and one coalesced latest barrier, so overlapping
switch, preliminary-stop, and final-stop barriers cannot strand the final waiter.
Every received barrier gets a new internal generation. The control writer checks
that generation again at handoff: reusing a wire `request_id` cannot let an earlier
worker or queued receipt settle the latest drain. Disconnect cancels the wait and
clears its reservation tracking. A final barrier after accepted requests and local
response writes finish establishes that prior terminal usage has been processed.
The Swift acknowledgement also passes through the ordered provider event queue,
so earlier inbound inference frames are refused before the barrier completes.
It is not a bearer credential or permission to serve. A stale idle heartbeat or
drain TTL cannot reopen this connection. Only a committing `models_replace`
(`validate_only` omitted or false) against the latest settled drain, followed by
successful receipt delivery and matching provider readiness, resumes the same connection; a restart instead
registers and authorizes a new connection. Code:
`coordinator/api/provider_completion_barrier.go` (`providerCompletionBarrier`),
`coordinator/api/provider_drain_ack.go` (`providerDrainAcker`),
`coordinator/api/provider.go` (`providerReadLoop`),
`coordinator/registry/drain_state.go` (`CommitProviderDrain`, `ProviderDrainPending`, `WriteProviderDrainAck`),
`provider-swift/Sources/ProviderCore/Coordinator/CoordinatorClient+Drain.swift`
(`acknowledgeDrain`).

Missing/late acknowledgements, including an older coordinator that does not
support these additive frames, never imply success. Normal shutdown remains
draining and returns non-success at its deadline. Explicit force is separate.
Existing `heartbeat.status = draining` and typed `inference_error` draining
rejections remain compatible. The legacy string `provider draining for update`
is retained for load/prefetch and old rejection classifiers even on lifecycle
drains. Legacy authorization diagnostics can report `authorization.path = legacy`
without App Attest serving enabled; this is a current registry verdict, not a
change to legacy eligibility.
When public authorization is absent, `authorization.path = self_route` reports
an authenticated owner's existing private/preferred-owner liveness and privacy
checks (`ProviderOwnerServingAuthorized` in `coordinator/registry/owner_authorization.go`).
It relaxes only the existing owner trust floor; it does not grant public routing,
change dispatch policy, or infer authorization from an `online` status.

All healthy planned disconnects use the drain barrier: lifecycle replacement,
manual/background update activation, late APNs registration, and model-inventory
reconciliation. Reconnect admission reopens only on the fresh session. A timeout
defers the reconnect/update rather than cancelling accepted inference. If a
barrier may have permanently fenced the old session, admission remains closed
until a confirmed drain and reconnect. Unexpected transport loss and explicit
force/fault recovery retain their cancellation paths; a dead connection cannot
deliver a graceful-drain acknowledgement.



## Envelope and the single-parse rule

| Rule | Go | Swift |
|---|---|---|
| Discriminator | top-level `"type"` string | same |
| Decode | `DecodeProviderMessage` first tries the single-walk chunk scanner (`coordinator/protocol/chunk_scan.go`, `scanChunkFrame`); unsupported shapes fall back to `ProviderMessage.UnmarshalJSON` (`coordinator/protocol/messages.go`), which reads `type` with `scanTopLevelString` (`coordinator/protocol/type_scan.go`), a byte walk over the top-level keys, then `json.Unmarshal`s the frame **once** into the concrete struct | `ProviderMessage.init(from:)` / `CoordinatorMessage.init(from:)` decode `TypeValue` then switch (`Messages.swift`) |
| Scanner fallback | escaped string, non-string value, malformed input or missing key → decode a `struct{ Type string }` envelope first (the historic double parse), so error behaviour is unchanged | — |
| Unknown type | `protocol: unknown message type %q` | `DecodingError` — the decoder **throws**, so the coordinator version-gates `desired_models`, `prefetch_model`, `load_model` and `capacity_probe` sends |
| Tests | `coordinator/protocol/type_scan_test.go` (`TestProviderMessageUnmarshalScanEquivalence`), `messages_envelope_test.go`, `messages_bench_test.go` | `provider-swift/Tests/ProviderCoreTests/Protocol/ProtocolTests.swift` |

## Message inventory

| Direction | `type` | Go struct | Swift case |
|---|---|---|---|
| provider → coordinator | `register` | `RegisterMessage` | `ProviderMessage.register` (`Register`) |
| provider → coordinator | `heartbeat` | `HeartbeatMessage` | `.heartbeat` (`Heartbeat`) |
| provider → coordinator | `service_reservation_released` | `ServiceReservationReleasedMessage` | `.serviceReservationReleased` |
| provider → coordinator | `inference_accepted` | `InferenceAcceptedMessage` | `.inferenceAccepted` |
| provider → coordinator | `inference_response_chunk` | `InferenceResponseChunkMessage` | `.inferenceResponseChunk` |
| provider → coordinator | `inference_complete` | `InferenceCompleteMessage` | `.inferenceComplete` |
| provider → coordinator | `inference_error` | `InferenceErrorMessage` | `.inferenceError` |
| provider → coordinator | `attestation_response` | `AttestationResponseMessage` | `.attestationResponse` |
| provider → coordinator | `code_attestation_response` | `CodeAttestationResponseMessage` | `.codeAttestationResponse` |
| provider → coordinator | `model_autopilot_status` | `ModelAutopilotStatusMessage` (`model_autopilot.go`) | `.modelAutopilotStatus` |
| provider → coordinator | `load_model_status` | `LoadModelStatusMessage` | `.loadModelStatus` |
| provider → coordinator | `prefetch_model_status` | `PrefetchModelStatusMessage` | `.prefetchModelStatus` |
| provider → coordinator | `models_update` | `ModelsUpdateMessage` | `.modelsUpdate` |
| provider → coordinator | `models_replace` | `ModelsReplaceMessage` | `.modelsReplace` |
| coordinator → provider | `models_replace_ack` | `ModelsReplaceAckMessage` | `.modelsReplaceAck` |
| provider → coordinator | `models_replace_ready` | `ModelsReplaceReadyMessage` | `.modelsReplaceReady` |
| coordinator → provider | `models_replace_resumed` | `ModelsReplaceResumedMessage` | `.modelsReplaceResumed` |
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
| coordinator → provider | `model_autopilot` | `ModelAutopilotMessage` (`model_autopilot.go`) | `.modelAutopilot` |
| coordinator → provider | `model_autopilot_control` | `ModelAutopilotControl` (`model_autopilot.go`) | `.modelAutopilotControl` |
| coordinator → provider | `load_model` | `LoadModelMessage` | `.loadModel` |
| coordinator → provider | `prefetch_model` | `PrefetchModelMessage` | `.prefetchModel` |
| coordinator → provider | `desired_models` | `DesiredModelsMessage` | `.desiredModels` |
| coordinator → provider | `trust_status` | `TrustStatusMessage` | `.trustStatus` |
| coordinator → provider | `capacity_probe` | `CapacityProbeMessage` (`capacity.go`) | `.capacityProbe` |

There is no standalone `unload` or `unload_model` message. Explicit opted-in
unloading uses [`model_autopilot`](#model_autopilot); see
[Model unloading](#model-unloading).

## Provider → coordinator

### `register`

Go `RegisterMessage` · Swift `ProviderMessage.Register`. Sent once per
connection, first.

| JSON key | Go | Swift | Presence | Notes |
|---|---|---|---|---|
| `hardware` | `Hardware` | `HardwareInfo` | req | [`hardware`](#hardware) |
| `models` | `[]ModelInfo` | `[ModelInfo]` | req | [`models[]`](#models) |
| `backend` | `string` | `String` | req | e.g. `"mlx-swift"`; the coordinator sends `load_model`, `prefetch_model` and `desired_models` only to `backend == "mlx-swift"` |
| `model_autopilot` | `*ModelAutopilotState` | `ModelAutopilotSnapshot?` | opt | Explicit consent and resident ownership; [state object](#model_autopilot-state). Missing state does not grant consent; scheduling/reconciliation requires a fresh paired backend-capacity snapshot |
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
| `template_hashes` | `map[string]string` | `[String: String]` | opt | template name → SHA-256 (includes `mlx_metallib`); Swift omits when empty |
| `privacy_capabilities` | `*PrivacyCapabilities` | `PrivacyCapabilities?` | opt | [`privacy_capabilities`](#privacy_capabilities) |

A verified registration whose durable state cannot be recovered after bounded
retries closes with WebSocket code **1013** (`StatusTryAgainLater`). It receives
no inference work while recovery is pending. The provider's normal reconnect
retries registration; this is a transient store failure, not failed attestation
(`coordinator/api/provider.go`, `verifyProviderAttestation`;
`coordinator/api/provider_restore.go`, `restorePersistedProviderState`).

#### `hardware`

Go `Hardware` · Swift `HardwareInfo`. All fields required.

| JSON key | Go | Swift |
|---|---|---|
| `machine_model` | `string` | `String` |
| `chip_name` | `string` | `String` |
| `chip_family` | `string` | `ChipFamily` (`"M1"`, `"M2"`, `"M3"`, `"M4"`, `"M5"`, `"M6"`, `"Unknown"`; `Protocol/Enums.swift`) |
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
| `native_media_tools` | `bool` | `Bool?` | opt | Per-model forced-media/tool-result-media support; absent/false is ineligible. Requires `is_vision` and matching `tool_constraint_protocol`/`tool_constraint_models`. Carried by registration and `models_update`; Swift omits nil and preserves explicit false. See `coordinator/registry/native_media_tools.go` (`providerSupportsNativeMediaToolsLocked`) |
| `template_render_ok` | `*bool` | `Bool?` | ptr | 0.6.5+; **explicit `false` survives the wire** and excludes the model from tool requests; absent = no opinion |
| `tool_constraint_template_hash` | `string` | `String?` | opt | binds grammar capability to the loaded template bytes |
| `estimated_memory_gb` | `float64` | `Double` | Go opt; Swift always encodes | Full load estimate in GiB; explicit native Qwen4 offload or MiMo LOAD declarations require the family-matched supplement and source/catalog consistency checks |
| `ssd_offloaded_weight_bytes` | `int64` | `UInt64?` | opt | Validated immutable payload excluded from native weight allocation; Swift omits nil/zero. It is not a KV cache byte count or a claim that OS-mapped pages use no RAM |
| `native_load_transient_bytes` | `int64` | `UInt64?` | opt | Checkpoint-derived allowance for eligible native Qwen4 SSD offload, or full-LOAD supplement above all stored payload bytes for validated exact `mimo_v2` with no SSD subtraction. Requires at least 1 GiB and checked addition; invalid/missing declarations retain legacy pricing. OS, activation and request-KV reserves are unchanged |
| `parameters` | — | `UInt64?` | Swift only | encoded by Swift, dropped by Go |

Both memory fields are defined by `coordinator/protocol/messages.go`
(`ModelInfo`) and `provider-swift/Sources/ProviderCore/Protocol/Types.swift`
(`ModelInfo`). The coordinator accepts the offload estimate only for native
Qwen4 types, an ID matching the requested model, finite positive memory, and a positive offloaded
payload smaller than the artifact; it floors the estimate against padded
remaining weight bytes (`coordinator/registry/offloaded_weights.go`,
`advertisedOffloadedMemoryGBLocked`). Missing/invalid declarations retain the
existing catalog/measurement policy. Exact `mimo_v2` additionally requires zero
SSD offload, positive source bytes, a checked supplement and a full estimate no
smaller than their sum. Its load floor retains the greater raw catalog/source
size plus the supplement once; callers supply raw decimal catalog GB, not GiB,
minimum RAM or a padded estimate. See [offloaded-weight admission](../architecture/routing.md#ssd-offloaded-model-weights).

#### `privacy_capabilities`

Go `PrivacyCapabilities` · Swift `PrivacyCapabilities`. Six required
booleans: `text_backend_inprocess`, `text_proxy_disabled`, `sip_enabled`,
`anti_debug_enabled`, `core_dumps_disabled`, `env_scrubbed`.

#### Prefix-cache objects

| Object | Fields |
|---|---|
| `PrefixCacheV2Capability` | Required: `model_id`, `model_aggregate_hash`, `prompt_contract_id`, `block_hash_version` (`string`); `block_size` (`uint32`); `cache_epoch` (`string`); `enabled`, `ready` (`bool`). Optional `ready_boundary_mode` (`string`): absent/empty retains legacy SSD coverage; `checkpoint` permits only explicitly committed input endpoints. Unknown values are rejected; the field is invalid on resident capabilities. `coordinator/registry/cache_capabilities_v2.go`, `validatePrefixCacheCapability` / `validateMemoryPrefixCacheCapabilities` |
| `PrefixCacheModelStatus` | `model_id`; `backend` ∈ {`contiguous`, `paged`, `unknown`}; `replay_strategy` ∈ {`direct`, `frozen_full`, `tail_replay`, `none`, `unknown`}; `state` ∈ {`ready`, `pending`, `disabled`, `error`}; `reason` ∈ {`ready`, `config_disabled`, `weight_hash_unavailable`, `runtime_identity_unavailable`, `unsupported_layout`, `unsupported_backend`, `paged_hybrid_unsupported`, `scan_pending`, `scan_failed`, `disk_unavailable`, `cache_init_failed`}. Enums validated at the coordinator boundary; Swift `PrefixCacheStatusBackend` / `ReplayStrategy` / `State` / `Reason` (`Messages.swift`) |
| `PrefixCacheDonationOutcomeCount` | `outcome` ∈ {`donated`, `below_effective_token_floor`, `no_complete_block`, `lossy_snapshot` (pre-0.8.0 compat), `incomplete_layer_state`, `stage_size_exceeded`, `write_rate_limited`, `write_priority_limited`, `write_queue_full`, `already_durable`, `already_queued`, `cache_closed`, `disk_unavailable`, `write_failed`, `host_memory_unavailable`, `cache_epoch_changed`, `cache_maintenance_busy`, `disk_space_insufficient`, `unsafe_cache_root`, `write_io_failed`, `existing_cache_unreadable`, `cache_entry_evicted`, `skipped_novel`}; `count` (`uint64`, monotonic per process). `cache_maintenance_busy` is emitted only by providers older than the per-file eviction change. Unknown future outcomes are ignored individually by older coordinators. `coordinator/registry/cache_eligibility.go`, `PrefixCacheDonationOutcomes`; Swift `PrefixCacheDonationOutcome` (`Messages.swift`). |
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
| `model_autopilot` | `*ModelAutopilotState` | `ModelAutopilotSnapshot?` | opt | Explicit consent and resident ownership; [state object](#model_autopilot-state). Missing state does not grant consent; scheduling/reconciliation requires a fresh paired backend-capacity snapshot |
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
| `whole_mac_service_retirement_protocol` | `int` | `Int?` | opt | `1` opts this connection into explicit attempt retirement via [`service_reservation_released`](#service_reservation_released); sticky after an accepted capacity report with a service total. Omission/unknown version on a new connection retains legacy terminal cleanup |
| `whole_mac_service_used` | `*float64` | `Double?` | opt | Fraction of the shared machine service allowance owned by requests until engine retirement; `[0,1]` |
| `whole_mac_service_reservations` | `[]WholeMacServiceReservation` | `[WholeMacServiceReservation]` | opt | Exact coordinator attempts included in the aggregate above; omitted when empty, including local-only work. Missing decodes to an empty list; [entry schema and reconciliation](#service-reservation-correlation) |
| `gpu_memory_active_gb`, `gpu_memory_peak_gb`, `gpu_memory_cache_gb` | `float64` | `Double` | req | Metal active / peak / reclaimable cache, shared across slots |
| `total_memory_gb` | `float64` | `Double` | req | |
| `free_for_load_gb` | `*float64` | `Double` (always encoded) | ptr | **The single source of truth for cold-load admission**: max additional model-weight GB loadable now, net of the unified-memory cap (`defaultCapFraction`, [`../architecture/hardware-support.md#constants`](../architecture/hardware-support.md#constants)), the OS/operator reserve and activation + minimum-KV headroom, clamped to real OS-available memory, with idle resident models counted as evictable. Nil (legacy provider) → the coordinator falls back to its total-memory heuristic |
| `load_usable_gb` | `*float64` | `Double?` | opt | Owner diagnostic: live GB available to the no-eviction load gate before activation/minimum-KV headroom. Zero is an observed zero; omission means an older provider or invalid sample. Not a routing input. |
| `load_headroom_gb` | `*float64` | `Double?` | opt | Owner diagnostic: current serving-set activation + minimum-KV reserve. A cold model needs `estimated_memory_gb + load_headroom_gb` out of `load_usable_gb`. Not a routing input. |
| `load_transition_active` | `*bool` | `Bool?` | opt | Owner diagnostic: a model load or load-gate update is in flight, possibly before a slot exists. When true, defer a cold-load memory verdict; omission means older provider. Not a routing input. |
| `mlx_cache_reclaimer` | `*MLXCacheReclaimerTelemetry` | `MLXCacheReclaimerTelemetry?` | opt | cumulative allocator-reclaim counters (`uint64`, reset on restart): `cache_limit_bytes`, `sweep_signals`, `reclaims`, `reclaimed_bytes`, `last_reclaimed_bytes`, `last_reclaim_duration_ms` |
| `capacity_seq` | `uint64` | `UInt64` | opt | per-connection monotonic snapshot sequence; the coordinator discards stale or reordered snapshots, and any `seq > 0` marks the connection quote-capable (`capacity_probe`). 0/omitted = legacy last-write-wins |
| `telemetry` | `*CapacityTelemetry` | `CapacityTelemetry?` | opt | [`backend_capacity.telemetry`](#backend_capacitytelemetry) |
| `prefix_cache_maintenance` | `*PrefixCacheMaintenanceTelemetry` | `PrefixCacheMaintenanceTelemetry?` | opt | Process-lifetime whole-root removal counters: `ttl_expired_total`, `budget_evicted_total`, `temp_removed_total`; includes unloaded models, separate from active-store evictions |

#### Service reservation correlation

Go `WholeMacServiceReservation` (`coordinator/protocol/whole_mac_service.go`) ·
Swift `WholeMacServiceReservation`
(`provider-swift/Sources/ProviderCore/Protocol/WholeMacServiceReservation.swift`).
Each `whole_mac_service_reservations[]` entry has this shape:

| JSON key | Go | Swift | Presence | Notes |
|---|---|---|---|---|
| `id` | `string` | `String` | req | Opaque UUID echoed from the attempt's [`service_reservation_id`](#inference_request); independent of the client request ID |
| `used_fraction` | `float64` | `Double` | req | Actual service allowance still held by this attempt; finite and in `(0,1]` |

The provider snapshots the aggregate and this list atomically. Entries remain
until engine retirement; local or legacy work without an attempt ID contributes
only to the aggregate. Lists are bounded to 64 unique UUIDs, and their fractions
must sum to no more than `whole_mac_service_used`. With a reported aggregate,
malformed correlation metadata fails admission closed at full usage.

The coordinator credits overlap only for an exact attempt ID, adding every
unmatched pending or terminal-shadow charge and any positive difference between
a matched local reservation and its reported fraction. Omitting the list while reporting the
total is supported but conservatively counts all pending and shadow reservations
in addition to that total. Omitting the total retains legacy admission only before
retirement-protocol opt-in; afterward omission fails service admission closed
and cannot reset ownership. The list alone cannot establish overlap. Receipt
time never proves inclusion. Terminal shadows are frozen attempt UUID/fraction
pairs retained until explicit release; absence from a heartbeat, even at a newer
`capacity_seq`, does not prove retirement.

#### `slots[]`

Go `BackendSlotCapacity` · Swift `BackendSlotCapacity`. One entry per loaded
model. Every engine-health, `kv_backend` and `telemetry` field is **measurement
only**: the coordinator decodes them into the routing snapshot but does not gate
routing on them.

| JSON key | Go | Swift | Presence | Notes |
|---|---|---|---|---|
| `model` | `string` | `String` | req | |
| `state` | `string` | `String` | req | Coordinator accepts `running`, `idle`, `idle_shutdown`, `crashed`, `reloading`; `registry.SlotStateFold` (`coordinator/registry/gate_reason.go`) folds anything else to `other`. The v0.8.16 provider emits `running`, `idle`, `crashed`, `reloading` (`provider-swift/Sources/ProviderCore/Inference/Engine/Bridge/EngineV2Bridge+Capacity.swift`); `idle_shutdown` stays accepted for older providers. `idle` means the model **is loaded** (`slotStateModelLoaded`, `coordinator/registry/scheduler.go`); `reloading`/`crashed` make the slot unroutable |
| `num_running`, `num_waiting` | `int` | `UInt32` | req | |
| `max_concurrency` | `int` | `UInt32` | opt | |
| `performance_profile` | `*ServingPerformanceProfileReference` | `ServingPerformanceProfileReference?` | opt | Reviewed profile identity; omitted when no exact qualified profile applies |
| `prompt_work_identity` | `*PromptWorkIdentity` | `PromptWorkIdentity?` | opt | Loaded engine artifact and prompt renderer identity, independent of prefix-cache enablement; missing evidence keeps heuristic count admission |
| `deadline_profile` | `*DeadlinePerformanceProfileReference` | `DeadlinePerformanceProfileReference?` | opt | Exact scheduler identity for measured first-content cells; grants no concurrency or chunk-policy change |
| `deadline_work` | `*DeadlineWork` | `DeadlineWork?` | opt | Coherent existing-owner work bounds; [schema below](#slotsdeadline_work) |
| `performance_measurements` | `*PerformanceMeasurements` | `PerformanceMeasurements?` | opt | Transient routing observations; [schema below](#slotsperformance_measurements) |
| `active_tokens` | `int64` | `Int64` | req | Σ (prompt + completion) tokens over running requests |
| `max_tokens_potential` | `int64` | `Int64` | req | Σ `max_tokens` over running requests |
| `observed_decode_tps` | `float64` | `Double` | opt | EWMA of per-request decode TPS |
| `observed_prefill_tps` | `float64` | `Double` | opt | Cold-prefill engine-phase EWMA, published at prompt completion; omitted when unmeasured |
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
| `recurrent_capture_disarmed_packed_total` | Optional complete-store counter: recurrent (GDN/SSM) donors whose checkpoint capture a packed prefill cohort disarmed, once per request (requests, including prompts below the 1,024-token floor that could never have written a file); absent from attention stores and from providers before the chunk-agnostic capture rule |
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
| `prefill_tokens_total` | `int64` | Actual computed prompt/suffix tokens at prompt completion, including later cancellations |
| `prefill_requests_total` | `int64` | Prompt-completion count paired with actual work, including fully reused zero-work prompts |
| `generated_tokens_total`, `generation_requests_total` | `int64` | Actual output and terminal counts, including partial cancelled generations |
| `isolated_prefill_tps` | `float64` | isolated prefill EWMA |
| `ewma_initialized` | `bool` | whether `isolated_prefill_tps` has a sample |
| `pump_tasks` | `int64` | live stream-pump tasks |
| `mtp_rounds_total`, `mtp_proposed_total`, `mtp_accepted_total` | `int64` | cumulative MTP counters |
| `kv_bytes_in_use`, `kv_bytes_capacity` | `int64` | raw bytes |
| `eval_in_flight_ms` | `int64` | same read as the slot-level key |
| `step_wall_ns_total`, `decode_rows_total` | `int64` | cumulative engine counters (slice 3) |

#### `slots[].performance_measurements`

`slots[].performance_profile` optionally names reviewed release data with `id`,
`runtime_revision` and `context_tokens`; optional `mtp` binds the actual verified
assistant artifact and effective decode settings (`enabled`, `artifact_sha256`,
`max_draft_tokens`, optional `fixed_draft_tokens`, `max_speculative_batch`,
`verification_mode`, `max_automatic_rectangular_tokens`). Omission means plain
target execution. The reference carries no self-certified curve or margin.
The coordinator resolves the reference against its own catalog and registered
model artifact. Go `coordinator/protocol/performance_profile.go` and Swift
`provider-swift/Sources/ProviderCore/Protocol/ServingPerformanceProfileReference.swift`
define the mirror.

`performance_measurements` is defined in
`coordinator/protocol/performance_measurements.go` and
`provider-swift/Sources/ProviderCore/Protocol/PerformanceMeasurements.swift`:

| Key | Meaning |
|---|---|
| `epoch` | Per-engine measurement lifetime; replacement resets counter baselines |
| `isolated_prefill`, `contended_prefill`, `decode`, `delivered_decode`, `end_to_end` | Optional `{tokens_per_second, sample_count, sample_age_ms}` observations; age is elapsed time at snapshot |
| `workload_buckets` | Bounded numeric buckets with `phase` (`prefill`, `decode`, `native_media_prefill`), `prompt_token_bucket`, `context_token_bucket`, `cache_state`, `contention`, `other_model_activity`, `observation`, and optional `concurrent_requests` (peak observed request overlap; 1–64; omitted by legacy providers) |

`native_media_prefill` records the target decoder's actual computed suffix for
owner-bound native media, after encoder preparation. It retains cache and
overlap classification but never updates `isolated_prefill` or
`contended_prefill`, and does not establish deadline or capacity eligibility.
Older coordinators discard this unknown diagnostic phase; existing scalar
observations and wire-message shapes remain compatible.

Prompt-completion receipts request a capacity refresh. Changed measurement
epochs, sample counts or cumulative work counters trigger the existing
rate-limited event heartbeat; sample-age changes alone do not. This uses the
existing payload and requires no additional wire message
(`CapacityHeartbeatMateriality`,
`provider-swift/Sources/ProviderCore/CapacityEventHeartbeats.swift`).

New peers use count/epoch/age to prevent heartbeat replay from refreshing old
samples. Malformed evidence clears its signal. Older peers may omit the entire
object and keep legacy changed-EWMA freshness behavior. No prompt text, token IDs
or cache keys appear in these measurements. Shared profiler fixtures pin the
Go/Swift shape; these are transient capacity fields, not persisted profiler
telemetry or telemetry-event fields. Numeric work counters remain in
`slots[].telemetry`; the epoch and bucket list are excluded from persisted
numeric-only provider telemetry.

#### `slots[].prompt_work_identity`

`PromptWorkIdentity` in `coordinator/protocol/prompt_work.go` mirrors
`provider-swift/Sources/ProviderCore/Protocol/PromptWork.swift`. The optional
object contains lowercase SHA-256 `model_artifact_hash` and `prompt_contract_id`
strings from the loaded engine's verified factory identity. It contains no
prompt content and does not enable prefix caching. Identity changes are material
capacity changes (`CapacityHeartbeatMateriality`).

The coordinator requires both values to match before using request count
provenance or an exact cache-plan count. A malformed or mismatched explicit
identity stays unqualified; it cannot borrow an older cache capability. Providers
without this field can establish the same pair through their existing validated
SSD or memory cache capability. Otherwise counts remain heuristic. These rules
do not change physical reservations, consumer usage or billing.

#### `slots[].deadline_profile`

Go `DeadlinePerformanceProfileReference` in
`coordinator/protocol/deadline_profile.go` mirrors
`provider-swift/Sources/ProviderCore/Protocol/DeadlinePerformanceProfileReference.swift`.
The coordinator resolves this reference against a separate reviewed deadline
catalog. It cannot change serving width, mixed-prefill policy or memory limits.

| Key | Meaning |
|---|---|
| `id`, `runtime_revision` | Immutable reviewed deadline profile and serving runtime |
| `configured_context_tokens` | Exact constructed context limit; individual measured cells may cover a smaller domain |
| `effective_max_concurrency` | Actual constructed scheduler width, not a requested override |
| `prefill_chunk_size`, `solo_prefill_stripe_tokens`, `max_concurrent_partial_prefills`, `mixed_prefill_token_cap` | Exact scheduler settings; optional fields preserve absence versus explicit values |
| `mtp` | Optional verified assistant identity/settings, with the same shape as `performance_profile.mtp` |
| `minimum_whole_mac_quiescence_ms` | Required explicit measured idle prerequisite; zero is distinct from absence |
| `minimum_nominal_stability_ms` | Required observed nominal/non-Low-Power stability interval |
| `power_mode` | Required exact measured power policy, currently `automatic` |

Changing any scheduler identity field withdraws the profile. Neither the
reference nor a heartbeat supplies calibrated rates or claims measured coverage
for the full configured context. Unsupported cells retain conservative fallback.
Missing applicability fields invalidate the reference. The provider withdraws
it during ineligible posture or activity; the coordinator also requires explicit
nominal thermal state and `backend_capacity.telemetry.low_power_mode=false`.

#### `slots[].deadline_work`

Optional Go `DeadlineWork` / Swift `DeadlineWork`, defined in
`coordinator/protocol/deadline_work.go` and
`provider-swift/Sources/ProviderCore/Protocol/DeadlineWork.swift`.

| Key | Meaning |
|---|---|
| `version` | `1`; unknown versions cannot qualify |
| `epoch` | Must match the slot's performance-measurement lifetime |
| `known` | False means ownership/work is incomplete; zero work must not be inferred |
| `prefill_tokens`, `decode_tokens` | Conservative work bounds of existing owners, including pre-submit and retiring leases |
| `request_count`, `context_tokens_max` | Existing owner count and maximum committed context |
| `service_fraction` | Held whole-Mac service fraction for these owners |

The provider snapshots these fields with aggregate service use and reservation
IDs under one lock. The coordinator validates freshness, counts and correlated
ownership before using a qualified contended cell. This optional object cannot
certify a profile, reduce memory reservations or change the request clock.
Providers omit it when no resident engine has a resolved deadline profile.
When any engine has such a profile, all slots retain work evidence, including
while the profile is temporarily ineligible, so competing work and recovery
remain observable.

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

### `service_reservation_released`

Go `ServiceReservationReleasedMessage` · Swift
`ProviderMessage.serviceReservationReleased` (via `OutboundMessage`).

| JSON key | Go | Swift | Presence | Notes |
|---|---|---|---|---|
| `type` | `string` | discriminator | req | `"service_reservation_released"` |
| `service_reservation_id` | `string` | `String` | req | Exact attempt UUID; no client request ID, prompt or output content |

A provider advertising retirement protocol `1` sends this reliable control frame
exactly once after the request pipeline can no longer acquire service and every
acquired service lease has retired. It also covers requests rejected before any
lease was acquired and leases acquired/released entirely between heartbeats.
A consumer terminal alone is not release evidence. The coordinator accepts proof
before terminal (preventing a later shadow) or after terminal (removing the
shadow and waking queued requests). Malformed, duplicate and unknown IDs allocate
no retained history. Late callbacks from an old connection cannot release a new
attempt. Definitively unsent writer attempts are retired locally; ambiguous
socket writes retain ownership until proof or disconnect. Transient untrust and
missing capacity do not clear ownership; disconnect clears all session state.
Legacy providers that do not opt in keep their existing terminal cleanup.
Coordinator tracking is decided at the final authorized handoff after this
connection opts in, including reservations created before capability arrived.
Attempts handed off before opt-in retain their original cleanup behavior; later
heartbeats do not upgrade them because their release proof may already have
arrived and been ignored under the legacy protocol.

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
| `error_reason` | `string` | `InferenceErrorReason?` | opt | closed, privacy-safe reason (`provider-swift/Sources/ProviderCore/Inference/Engine/InferenceFailure.swift`): `jinja_channel_tags`, `jinja_null_bridge`, `jinja_template`, `model_load`, `capacity_timeout`, `queue_full`, `token_budget_exhausted`, `media_memory_unavailable`, `request_exceeds_context`, `request_exceeds_node`, `request_exceeds_node_budget`, `request_exceeds_batch_token_budget`, `capacity_busy`, `deadline_unreachable`, `draining`, `cancelled`, `client_error`, `tool_noncompliance`. The typed `draining` reason on a 503 marks a transient update drain: no provider-health or capacity penalty, and no capacity retry charge (`coordinator/api/consumer.go`, `noteInferenceError`; `coordinator/api/dispatch.go`, `dispatchState.noteProviderError`). Swift emits it from `rejectIfDrainingForUpdate` (`provider-swift/Sources/ProviderCore/ProviderLoop+InferenceHandler.swift`). |
| `failure_code` | `InferenceFailureCode` | `InferenceFailureCode?` | opt | closed enum (`coordinator/protocol/inference_failure.go`): `invalid_request`, `invalid_media`, `media_too_large`, `unsupported_media`, `template_render`, `model_unavailable`, `capacity`, `cancelled`, `encryption_failure`, `generation_failure`, `internal_failure`. Swift always sets it (`InferenceFailure.code` is non-optional). A missing or unknown value is drift: `sanitizeProviderInferenceError` fails it closed as `generation_failure` and counts `inference.invalid_failure_code`; status, `error_reason` and `terminal_cause` never reclassify it |
| `terminal_cause` | `string` | `InferenceTerminalCause?` | opt | closed: `admission_timeout`, `prefill_stall`, `decode_stall`, `safety_deadline`, `backpressure_timeout`, `watchdog`, `cancelled`, `engine_error`. Unknown → treated as absent plus a drift metric (`coordinator/api/terminal_cause.go`); platform-policy terminals never strike health breakers |
| `attempt_usage` | `*UsageInfo` | `UsageInfo?` | opt | engine-reconciled usage of the failed attempt; observability only, never billing |
| `rejection_reason` | `CapacityRejectionReason` | `CapacityRejectionReason?` | opt | routing-v2 enriched rejection; enum shared with [`capacity_quote`](#capacity_quote) |
| `available_token_budget` | `*int64` | `Int64?` | ptr | **an explicit zero is encoded** (busy slot, zero free tokens); nil/absent = legacy frame |
| `feasible_after_ms` | `int64` | `Int64?` | opt | duration forecast, never a wall clock; Swift omits 0 |
| `capacity_seq` | `uint64` | `UInt64?` | opt | the snapshot the gate decided from; Swift omits 0 |
| `profile` | `json.RawMessage` | `InferenceProfile?` | opt | same contract as `inference_complete`; the sanitizer passes it through as opaque bytes |
| — (`CoordinatorCause`) | `json:"-"` | — | never on the wire | coordinator-synthetic only (`provider_disconnected`) |

`media_memory_unavailable` is a retryable `capacity`/503 failure for media
preparation, not a text/KV-budget observation. It carries no capacity enrichment
fields, does not strike model-wide capacity or health trackers, and still uses
the bounded failover budget. A contradictory native `terminal_cause` retains
normal terminal handling instead of this exemption. The provider emits it
through `MiMoV26EncodedMediaIngress.outwardFailure`; the coordinator enforces
the contract in `sanitizeProviderInferenceError`.

### `attestation_response`

Go `AttestationResponseMessage` · Swift `AttestationResponse`. Reply to
[`attestation_challenge`](#attestation_challenge).

| JSON key | Go | Swift | Presence | Notes |
|---|---|---|---|---|
| `nonce` | `string` | `String` | req | echoed |
| `signature` | `string` | `String` | req | base64 SE signature over nonce + timestamp (liveness) |
| `status_signature` | `string` | `String?` | opt | signature over the canonical JSON of nonce + timestamp + all status fields (`attestation.BuildStatusCanonical`, `coordinator/attestation/`). Swift always sends it; for a provider with an attested SE key an absent or empty value fails the challenge |
| `public_key` | `string` | `String` | req | base64 |
| `rdma_disabled`, `sip_enabled`, `secure_boot_enabled` | `*bool` | `Bool?` | opt | fresh posture at challenge time; Swift always sends all three, and an omitted value fails the challenge |
| `binary_hash`, `active_model_hash` | `string` | `String?` | opt | SHA-256 |
| `template_hashes`, `model_hashes` | `map[string]string` | `[String: String]` | opt | Swift omits when empty |

### `code_attestation_response`

Go `CodeAttestationResponseMessage` · Swift `CodeAttestationResponse`. `nonce`
(decrypted pushed nonce, base64) and `signature` (SE P-256 signature over the
nonce bytes), both required. Verified against the SE key bound at registration,
never a key carried in this message.

### `model_autopilot_status`

Go `ModelAutopilotStatusMessage` (`coordinator/protocol/model_autopilot.go`) ·
Swift `ModelAutopilotStatus`
(`provider-swift/Sources/ProviderCore/Protocol/Autopilot/ModelAutopilot.swift`).

| JSON key | Go / Swift | Presence | Meaning |
|---|---|---|---|
| `command_id` | `string` / `String` | req | Identifies the immutable command on this provider session |
| `status` | `string` / `State` | req | `started`, `succeeded`, `failed` |
| `error` | `string` / `String?` | opt | Diagnostic failure text; not an authorization or capacity signal |
| `model_autopilot` | `*ModelAutopilotState` / `ModelAutopilotSnapshot` | opt in Go; current Swift includes it | Provider command/residency state; status alone never changes scheduler capacity |

`Registry.HandleAutopilotStatus` accepts only the matching current session and
pending command. Completion requires a later accepted capacity sequence paired
with the same terminal command ID and matching actual residents
(`coordinator/registry/autopilot_provider_state.go`,
`reconcileAutopilotHeartbeatLocked`). Repeated status messages are acknowledgements,
not additional completed operations.

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

### `models_replace` / `models_replace_ack` / `models_replace_ready` / `models_replace_resumed`

Non-destructive target validation followed by atomic full inventory replacement
and resume on the same registered connection; `models_update` retains its existing
merge semantics.

| Message | Fields | Contract / source |
|---|---|---|
| `models_replace` | `request_id`, `drain_request_id`, nonempty `models`; optional `validate_only` (Bool, omitted means false), `tool_constraint_protocol`, `tool_constraint_models` | `coordinator/protocol/messages.go` (`ModelsReplaceMessage`); Swift `provider-swift/Sources/ProviderCore/Protocol/ModelsReplace.swift` (`ModelsReplace`) |
| `models_replace_ack` | matching `request_id`, `drain_request_id`, and echoed `validate_only` (Bool, always present), `accepted`; optional `error` | `coordinator/protocol/messages.go` (`ModelsReplaceAckMessage`); Swift `ModelsReplaceAck` |
| `models_replace_ready` | matching `request_id`, `drain_request_id`, and nonzero `capacity_seq` stamped after the provider opens local admission | `coordinator/protocol/messages.go` (`ModelsReplaceReadyMessage`); Swift `ModelsReplaceReady` |
| `models_replace_resumed` | exact `request_id`, `drain_request_id`, and `capacity_seq` from the accepted readiness frame | `coordinator/protocol/messages.go` (`ModelsReplaceResumedMessage`); Swift `ModelsReplaceResumed` |

`request_id` is nonempty and at most 64 bytes. `drain_request_id` must name the
latest committed **and settled** `provider_drain` on this exact live connection.
Every model ID must be unique and nonempty and meet the attested runtime
capability floor. When the catalog pins a hash, the model must carry the active
or an explicitly retained revision hash for that same model. Both validation
and commit check the current approvals, so retirement between those phases
rejects the replacement (`coordinator/registry/provider_models_replace.go`,
`ReplaceProviderModels`).
As with registration, off-catalog local models may be advertised regardless of
`private_only` or whether the provider has a linked owner; advertising them does
not grant trust or ownership. With a configured catalog, they are eligible only
for their owner's self-route or preferred-owner requests, never public routing.
Sources: `coordinator/registry/provider_lifecycle.go` (`Register`),
`coordinator/registry/model_catalog.go` (`modelServableForOwnerLocked`,
`providerServesCatalogModelLocked`).
The tool allowlist must contain unique selected IDs and use protocol 1; protocol
0 has no tool allowlist. The coordinator validates the entire set before mutation.
Pending inference reservations must be gone. Both phases require the same committed
and settled drain and validate the entire target. Rejection (`invalid_drain`,
`invalid_models`, or `disconnected`) does not mutate inventory or reopen the drain;
the provider may resubmit its old full set with `validate_only` false and the same
valid drain ID to resume.

Successful `validate_only: true` does not mutate any provider or registry state:
the old model/hash inventory, resident warm/current/slot evidence, trust, reputation,
challenge state, tool/cache/template capabilities, pending loads, routing indexes,
and settled drain are unchanged. The handler does not drain or reject queued work.
It is a preflight, not a reservation: the committing request revalidates the target.

Committing success preserves the provider object, session, trust, reputation, and
challenge state. Removed or hash-changed models lose warm/current/slot, pending-load,
template, and cache evidence; tool capabilities become the complete new allowlist.
Routing indexes reflect the new set immediately, but admission stays fenced until
the accepted committing acknowledgement is successfully written and the provider
reopens its own admission. It then sends `models_replace_ready` on the same
connection and emits a refreshed capacity heartbeat. The coordinator checks
the ready frame's request and drain IDs, then waits for an accepted `idle` or
`serving` heartbeat with `backend_capacity.capacity_seq` at least as new as the
nonzero sequence in readiness before resuming routing; either message may arrive
first. Earlier or stale `capacity_seq`, draining status, and omitted
capacity cannot release the fence. A failed write or missing readiness
does not dispatch or reject queued work and does not force a reconnect. A later
drain or another session cannot be reopened by stale readiness. Removed-model
queue cleanup survives a later same-session reconciliation drain and is consumed
only when routing resumes or the session disconnects. After resume the
coordinator sends a fresh `desired_models` snapshot
for the replaced inventory, bypassing its prior-snapshot deduplication, then
reconciles queues including requests for removed models. It then sends
`models_replace_resumed` on the same connection. The provider reports switch
success only after receiving the matching receipt. Before sending readiness,
the provider restores its prefetch subsystem; a desired snapshot received in
the brief restoration gap is deferred and a newer snapshot supersedes it.
If the receipt is lost or the connection drops, the result is unconfirmed even though routing may have
resumed; retrying the same readiness frame on that connection resends the
receipt without repeating the routing transition. A newer drain invalidates
that retry. A drain remains reusable
after validation but not after commit or disconnect. Sources:
`coordinator/registry/provider_models_replace.go` (`ReplaceProviderModels`, `ResumeProviderModels`),
`coordinator/api/provider_models_replace.go` (`handleModelsReplace`, `handleModelsReplaceReady`).

Swift `prepareModelSwitch(timeout:)` returns the settled drain ID or nil.
`validateModelSelectionAfterDrain(_:drainID:timeout:)` checks the candidate before
the runtime unloads any resident model; it neither stages the candidate advertisement
or hashes nor consumes the acknowledged drain, including on rejection or timeout.
`replaceModelsAfterDrain(_:drainID:timeout:)` then commits. Both use the same sender
and receipt waiter, correlating the request ID, drain ID, phase, and exact connection
without reconnecting. A validation timeout is not validation success, but cannot
change the inventory. A committing timeout or dropped connection is an **unknown
outcome**, never success: the intended inventory and hashes remain staged for any
ordinary reconnect, and the runtime keeps admission closed until reconciliation.
An explicit commit rejection restores the client's pre-call advertisement; the
runtime owns local and durable rollback. Sources:
`provider-swift/Sources/ProviderCore/Coordinator/CoordinatorClient+Drain.swift`,
`provider-swift/Sources/ProviderCore/Coordinator/CoordinatorClient+ModelSwitch.swift`.

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
| `capacity_seq` | `uint64` | req | snapshot the quote was computed from; `applyFirstContentQuote` (`coordinator/registry/first_content_plan.go`) rejects older accepted-capacity sequences and newer local reservations; response correlation remains bounded by `capacityProbeWindow` |
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
| `service_reservation_id` | `string` | `String?` | opt | Fresh opaque UUID for the committed service reservation, including retries of the same request; omitted by older coordinators. The provider echoes it with the actual held charge in [`whole_mac_service_reservations`](#service-reservation-correlation) until retirement. Distinct from `request_id`; missing or invalid IDs receive no overlap credit but still consume provider allowance |
| `encrypted_body` | `*EncryptedPayload` | `EncryptedPayload?` | opt | NaCl box; the only request body. There is no plaintext `body` key: the coordinator never sends one and Swift rejects a request without `encrypted_body` |
| `first_content_budget_ms` | `int64` | `Int64?` | opt | positive time left for this attempt to produce its first content chunk; 0 omitted. The coordinator omits this for accounts outside `EIGENINFERENCE_FIRST_CONTENT_SLA_ACCOUNTS`; missing means no coordinator first-content SLA, preserving existing Swift decoding |
| `prompt_work` | `*PromptWork` | `PromptWork?` | opt | Numeric artifact/template-bound count provenance; older peers may omit it. Validated after provider tokenization; never changes billing usage or the inherited deadline |
| `cache_receipt_nonce` | `string` | `String?` | opt | binds the prefix-cache receipts to this attempt |
| `cache_scope` | `string` | `String?` | opt | |
| `prefix_cache_protocol` | `int` | `Int?` | opt | |
| `cache_receipt_boundary_mode` | `string` | `String?` | opt | `checkpoint` echoes support for the selected SSD capability. A provider emits checkpoint-mode receipts only with this echo; an older coordinator omits it and remains cold for this format. Copied from the prepared attempt and cleared on retry/fallback; `coordinator/api/provider_wire.go`, `snapshotProviderInferenceFrame` / `wireMessage`; `coordinator/registry/cache_receipts.go`, `ForgetCacheAttempt` |
| `cache_repeated_prefix_tokens` | `*int` | `Int?` | ptr | Coordinator-observed fleet-wide repeat demand: the deepest boundary another plan shared within the routing TTL among those a plan observes (multiples of 1,024 tokens, the final boundary, and a power-of-two ladder for very long prompts), 0 when none. Sent only with a granted scope; absent from older coordinators (providers then write every checkpoint) and cleared on retry/fallback (`CacheAttemptSnapshot.ApplyTo`, `coordinator/registry/cache_attempt_ownership.go`). Integer count only, never a key, hash or boundary. Providers gate complete-checkpoint donations on it (`skipped_novel`; `SSDCheckpointDemand.admitsWrite`, `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDCheckpointDemand.swift`). Swift clamps a negative value to 0. The e2e wire relay projects it for `inference_request` (`copyFields`, `e2e/testbed/provider_wire_relay.go`) |
| `tool_schema_metadata_protocol` | `int` | `Int?` | opt | `1` = the coordinator rejected client-forged reserved keys before normalisation |

`prompt_work` is defined in `coordinator/protocol/prompt_work.go` and
`provider-swift/Sources/ProviderCore/Protocol/PromptWork.swift`:

| Key | Meaning |
|---|---|
| `version` | `1`; unknown versions remain decodable but unqualified |
| `source` | `exact_contract`, `calibrated_template`, or `heuristic` |
| `prompt_tokens` | Positive central input count, bounded by 1,048,576 tokens |
| `upper_bound_tokens` | Exact count for exact provenance; measured upper bound for qualified calibration; `0` denotes unknown heuristic uncertainty |
| `model_artifact_hash`, `prompt_contract_id` | Lowercase SHA-256 identities required for qualified provenance |
| `calibration_id` | Required printable reviewed-corpus identity for `calibrated_template`; absent for exact counts |

The fields contain no content, token IDs, cache keys or consumer identity.
An exact count must equal the provider's actual tokenization; a calibrated
count must bound it. Invalid identity, unknown source or an exceeded bound
withdraws calibrated admission and preserves the conservative fallback.
The provider ignores a malformed optional `prompt_work` object and decodes the
rest of the inference request normally; required request fields remain strict.

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

### `model_autopilot`

Go `ModelAutopilotMessage` (`coordinator/protocol/model_autopilot.go`) · Swift
`ModelAutopilotCommand` (`provider-swift/Sources/ProviderCore/Protocol/Autopilot/ModelAutopilot.swift`).
Sent only for explicit, compatible provider consent under live control after
whole-device reservation. Shadow leases cannot authorize this message.

| JSON key | Go / Swift | Presence | Meaning |
|---|---|---|---|
| `command_id` | `string` / `String` | req | Nonempty, at most64 bytes; exact payload/ID reused for bounded retries |
| `session_id`, `revision` | `string` / `String` | req | Must match the live control connection and approved consent revision; a started operation retains ownership until its terminal snapshot even when control or consent changes |
| `reason` | `string` / `String?` | opt | Closed reason: `demand`, `bootstrap`, `protected_floor`, or `idle_surplus`; displayed with target/victims, never free-form authorization |
| `load_model_id` | `string` / `String?` | opt | One advertised local cached build; omitted for unload-only commands |
| `unload_model_ids` | `[]string` / `[String]` | req | Explicit victims within `selected_models`, unique and at most32; `[]` means no eviction |
| `expected_resident_models` | `[]string` / `[String]` | req | Complete unique resident set expected before mutation, at most32 |
| `expires_at_ms` | `int64` / `Int64` | req | Unix milliseconds; must be in the future and no more than300s ahead at first acceptance; coordinator's configured default window is in [configuration](configuration.md#model-autopilot) |
| `lease_seconds` | `int` / `Int` | req | `0...86400`; minimum hold lease on a newly loaded target, separate from provider residence/idle dwell |

The provider rejects a changed resident set, busy device, pinned/young victim,
active lease, unsupported hardware, missing local primary/assistant or infeasible
total victim memory. A command must load a model or name at least one victim;
the target cannot also be a victim. It calls `ensureModelLoaded` with
`allowEviction: false` and retains disk files. Expiry bounds acceptance and first
mutation, not completion after a transition already began.

Every load target and unload victim must belong to the selected-model allowlist;
otherwise `ModelAutopilotPolicy.rejection` returns `model_not_selected`
(`provider-swift/Sources/ProviderCore/Autopilot/ModelAutopilotPolicy.swift`). The
provider's separate guarded local cleanup of superseded, unadvertised residents
is not permission for a coordinator command to unload an unselected model.

The provider caches a bounded command history. An identical active/completed
command returns its existing status; reused IDs with altered payload are
rejected. Same-ID recovery never extends the original expiration. See
[autopilot ownership](../architecture/model-autopilot.md#invariants).

### `model_autopilot_control`

Go `ModelAutopilotControl` (`coordinator/protocol/model_autopilot.go`) · Swift
`ModelAutopilotControl` (`provider-swift/Sources/ProviderCore/Protocol/Autopilot/ModelAutopilot.swift`).
Sent only to protocol-3 explicit enrollments, bound to the current connection and
approved configuration.

| JSON key | Go / Swift | Presence | Meaning |
|---|---|---|---|
| `type` | `string` / `String` | req | `"model_autopilot_control"` |
| `session_id`, `revision` | `string` / `String` | req | Current control connection and approved consent revision |
| `enabled` | `bool` / `Bool` | req | Whether this lease permits participation; consent is independently required |
| `observe_only` | `bool` / `Bool` | req; always emitted | `true` is shadow observation only and grants no residency ownership; `false` can activate live control after a matching acknowledgement |
| `expires_at_ms` | `int64` / `Int64` | req | Unix-millisecond lease expiry; bounds are in [configuration](configuration.md#model-autopilot) |

A matching unexpired shadow lease reports mode without activating control;
absent/expired control leaves ordinary policy in force unless the user explicitly
paused residency. Only a matching live lease can transfer residency ownership.

### `load_model`

Go `LoadModelMessage` · Swift `LoadModel`. `model_id` (req). Sent only to
`backend == "mlx-swift"`; the provider replies with `load_model_status`.
Active or explicitly paused Autopilot providers block this legacy residency path and use explicit
`model_autopilot` commands instead.

### `prefetch_model`

Go `PrefetchModelMessage` · Swift `PrefetchModel`. `model_id` (req); `priority`
(`int`, opt, advisory). Download + verify only, no GPU load; the provider
replies with `prefetch_model_status` and then `models_update`.

### `desired_models`

Go `DesiredModelsMessage` · Swift `DesiredModels`. `models` (`[]DesiredModelEntry`):
`model_name` (public alias or concrete model ID), `desired_build` (concrete build ID),
`previous_build` (optional; still acceptable mid-rollout), `revision` (optional version),
`aggregate_sha256` (optional artifact hash). `DesiredModelsForProvider` in
`coordinator/registry/model_commands.go` adds the revision fields and unaliased
concrete-model entries only for providers reporting `model_revisions_v1` in
`runtime_capabilities`. This is protocol feature detection, not a new trust grant.

Sent right after `register`, when desired identities or eligible capabilities
change, and freshly recomputed after matching provider readiness for a committed
replacement even when the snapshot equals the one sent before switching. The same
backend and attested capability guards apply. Alias entries describe aliases
whose desired, previous, or retired build is in the provider's advertised inventory;
an empty set revokes old targets. Revision-aware providers stage the exact artifact
and drain before activation; ID-only providers retain the legacy prefetch path.
Both announce completed updates through `models_update`. Source:
`coordinator/registry/model_commands.go` (`DesiredModelsForProvider`, `RefreshDesiredModels`).
See [revision lifecycle](../architecture/model-revisions.md).

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

## App Attest protocol 3 hardware binding

`register.app_attest_protocol=3` negotiates the account/endpoint-bound shadow
exchange plus signed static hardware claims. `AppAttestStatus` adds optional
string fields `machine_model`, `memory_gb`, `cpu_total`, `cpu_performance`,
`cpu_efficiency`, `gpu_cores` and `attestation_public_key`; the version 3
transcript hashes them after the status fields under its own domain. It is the
only transcript: cached-response recovery resumes only a protocol-3 enrollment.
These fields
are app measurements, not Apple-certified hardware. See
[the App Attest reference](app-attest-shadow.md) and
`coordinator/protocol/app_attest_hardware.go` (`AppAttestShadowHashV3`).

## Shared objects

### `model_autopilot` state

Swift also embeds `ModelAutopilotSnapshot` in the local daemon-state file.
From 0.9.16 the local file uses `autopilot_state` so the old 0.9.15 watchdog
ignores this optional detail and can still validate heartbeat health. New readers
also accept the old local `autopilot` key (`DaemonState+Coding.swift`). Its
decoder accepts both explicit wire keys and the state reader’s converted keys,
including nested residents and load history. Wire field names and requiredness
are unchanged (`ModelAutopilotSnapshot+Decoding.swift`).

Go `ModelAutopilotState` · Swift `ModelAutopilotSnapshot`, declared in the
`model_autopilot.go` / `ModelAutopilot.swift` files cited above. It appears on
registration and heartbeat, and in command status. The negotiated `protocol`
value, rather than a provider version string or advertised inventory, identifies
support.

| JSON key | Go / Swift | Presence | Meaning |
|---|---|---|---|
| `protocol` | `int` / `Int` | req | `3` for separate planning inventory and session activation |
| `enabled`, `cached_only` | `bool` / `Bool` | req | Explicit consent and cached-only scope; both must be true for planning |
| `active`, `paused` | `bool` / `Bool` | req | Acknowledged live control and explicit local pause |
| `observe_only` | `bool` / `Bool` | req; always emitted | Acknowledged shadow mode; a valid shadow lease reports `true` with `active=false` and the matching session |
| `session_id` | `string` / `String?` | opt | Acknowledged control connection; shadow acknowledgement is not live ownership |
| `revision` | `string` / `String` | req | Approved consent configuration |
| `selected_models` | `[]string` / `[String]` | req | Consent requires `1...256` exact verified cached network build IDs, each nonempty and at most `256` UTF-8 bytes; static until explicit inventory refresh, empty never grants permission |
| `min_idle_seconds` | `int` / `Int` | req | Inactivity guard separate from minimum residence |
| `load_history` | `[]ModelAutopilotLoadTiming` / `[ModelAutopilotLoadTiming]?` | opt | At most64 `{model_id, weight_hash, load_ms, measured_at_ms}` measurements; only recent matching bytes influence estimates |
| `last_elapsed_ms`, `last_release_ms`, `last_load_ms` | `int64` / `Int64?` | opt | Measured last operation phases; no ETA guarantee |
| `min_dwell_seconds` | `int` / `Int` | req | Provider minimum residence before replacement; inactivity is separate |
| `pinned_models` | `[]string` / `[String]` | req | Up to256 protected model IDs |
| `max_model_slots` | `int` / `Int` | req | Valid planning range `1...32` |
| `resident_models` | `[]ModelAutopilotResident` / `[ModelAutopilotResident]` | req | Unique resident inventory, at most32; must match the paired capacity snapshot |
| `free_for_load_no_evict_gb` | `*float64` / `Double?` | opt | Weight-only incoming headroom in GiB with all residents retained; absent is unknown and cannot authorize a load |
| `active_command_id`, `last_command_id` | `string` / `String?` | opt | Current owner and most recent terminal command ID |
| `last_command_status` | `string` / `State?` | opt | Most recent terminal `succeeded` or `failed` state for reconciliation |

Resident entries:

| JSON key | Go / Swift | Presence | Meaning |
|---|---|---|---|
| `model_id` | `string` / `String` | req | Concrete build ID |
| `resident_seconds`, `idle_seconds` | `float64` / `Int` | req | Nonnegative durations; current Swift emits whole seconds |
| `weights_gb` | `float64` / `Double` | req | Scanner-padded load estimate, not reclaimable free memory |
| `resident_gb` | `*float64` / `Double?` | opt | Actual slot-owned weight bytes expressed in GiB; the only victim reclaim credit, not OS RSS |

State validation and malformed-report fencing are in
`coordinator/registry/autopilot_provider_state.go` (`validAutopilotState`,
`cloneAutopilotState`, `autopilotStateMatchesCapacity`). A status frame cannot
replace the paired heartbeat, clear an uncertain operation by age alone or
make unconfirmed slots routable.

Provider `enabled` is configured consent, not activation. It does not itself
activate warm-only network admission. The default shadow rollout sends leases for
explicit mode/status but no residency commands. Shadow lease acknowledgement is
not live ownership or actual capacity credit.

The `selected_models` allowlist is populated by verified active downloaded network
inventory, not a model picker, arbitrary local/off-catalog discovery or a download
request. It can be broader than saved `enabled_models`; its metadata is carried
in optional `register.autopilot_inventory` (`[]ModelInfo`, at most 256 entries),
not in ordinary `register.models`. Only consented IDs with a nonempty verified
weight hash are accepted. Ordinary models win duplicate IDs and weight identity.
Observation-only models do not grant public/owner routing, capacity or legacy
load permission until a matching live lease is acknowledged. Shadow planning
can inspect that metadata without granting permission. Old coordinators ignore
the additive field and cannot activate protocol 3. Both the ordinary JSON encoder
and the raw-attestation registration encoder preserve this separation. Ordinary
restarts reuse the recorded inventory rather than automatically consenting to
new catalog builds. Implementation: `coordinator/registry/autopilot_inventory.go`,
`provider-swift/Sources/ProviderCore/Coordinator/CoordinatorClientCodec.swift`.

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

## Model unloading

Opted-in providers under a live control lease accept explicit victim lists through `model_autopilot`.
There is no separate generic unload command. The provider's ordinary idle timer
is paused during active control or an explicit pause. Recorded consent alone
does not pause it during shadow, while waiting or after lease expiry. Commands cannot fall through to implicit LRU
victims. Standalone surplus unloading follows the configured quiet window; load-driven replacement
still requires all dwell, memory, pin and donor protections.

Non-enrolled providers keep their existing idle and legacy model lifecycle.
`desired_models` release reconciliation remains independent, is deferred behind
an active autopilot owner and resumes afterward. Explicitly superseded models
have a guarded cleanup path so the paused idle timer does not retain retired
builds. The coordinator observes actual results through the paired resident and
backend-capacity heartbeat. See [autopilot architecture](../architecture/model-autopilot.md).

## Tests that pin the wire

| Layer | Files |
|---|---|
| Go shape and envelope | `coordinator/protocol/messages_register_heartbeat_test.go`, `messages_backend_capacity_test.go`, `messages_inference_test.go`, `messages_terminal_cause_test.go`, `messages_attestation_test.go`, `messages_model_lifecycle_test.go`, `messages_envelope_test.go`, `prefix_cache_v2_test.go`, `prefix_cache_telemetry_test.go`, `capacity_test.go`, `inference_failure_test.go`, `tool_constraints_test.go`, `type_scan_test.go` |
| Autopilot command/state | `coordinator/protocol/model_autopilot_test.go`; `provider-swift/Tests/ProviderCoreTests/Autopilot/ModelAutopilotTests.swift` |
| Go ↔ Swift key pinning | `coordinator/api/provider_wire_test.go`; `provider-swift/Tests/ProviderCoreTests/Protocol/ProtocolTests.swift`, `CapacityQuoteProtocolTests.swift` |
| `profile` fixture | `coordinator/protocol/testdata/profiler_wire_fixture.json` — written by Go, loaded by Swift |

## Related

- [`../architecture/scheduling.md`](../architecture/scheduling.md) — how slot state and budgets drive admission
- [`../architecture/routing.md`](../architecture/routing.md) — gate reasons and candidate selection
- [`../architecture/system-profiler.md`](../architecture/system-profiler.md) — the `profile` object, `request_profiles`, `fleet_snapshots`
- [`../architecture/telemetry.md`](../architecture/telemetry.md) — what the coordinator does with heartbeat data
- [`telemetry-inventory.md`](telemetry-inventory.md) — producer, sink and cadence of every datum
- [`api-contracts.md#headers`](api-contracts.md#headers) — the `X-Timing` header
