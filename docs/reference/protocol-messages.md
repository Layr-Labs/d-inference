# Provider ↔ Coordinator Protocol Messages

The provider WebSocket is mounted at `GET /ws/provider`. All messages are JSON with a top-level `type` discriminator. Canonical Go definitions live in [`coordinator/protocol/messages.go`](../../coordinator/protocol/messages.go); the Swift mirror lives in [`provider-swift/Sources/ProviderCore/Protocol/Messages.swift`](../../provider-swift/Sources/ProviderCore/Protocol/Messages.swift) and shared types in [`provider-swift/Sources/ProviderCore/Protocol/Types.swift`](../../provider-swift/Sources/ProviderCore/Protocol/Types.swift).

## Message direction summary

| Direction | Types |
|---|---|
| Provider → Coordinator | `register`, `heartbeat`, `inference_accepted`, `inference_response_chunk`, `inference_complete`, `inference_error`, `attestation_response`, `code_attestation_response`, `load_model_status`, `prefetch_model_status`, `models_update` |
| Coordinator → Provider | `inference_request`, `cancel`, `attestation_challenge`, `runtime_status`, `load_model`, `prefetch_model`, `desired_models`, `trust_status` |

Unknown provider→coordinator types are rejected by [`ProviderMessage.UnmarshalJSON`](../../coordinator/protocol/messages.go).

## Provider → Coordinator messages

### `register`

Sent on WebSocket connect. Go: [`RegisterMessage`](../../coordinator/protocol/messages.go); Swift: `ProviderMessage.Register`.

| Field | Type | Required | Notes |
|---|---|---|---|
| `type` | string | yes | `"register"` |
| `hardware` | object | yes | [`Hardware`](#hardware) |
| `models` | array | yes | [`ModelInfo`](#modelinfo) list |
| `backend` | string | yes | e.g. `"mlx-swift"` |
| `version` | string | no | Provider binary semver |
| `public_key` | string | no | Base64 X25519 public key for E2E encryption |
| `encrypted_response_chunks` | bool | no | Whether text response chunks are returned encrypted |
| `attestation` | raw JSON | no | Signed Secure Enclave attestation blob |
| `prefill_tps` / `decode_tps` | number | no | Benchmark throughput |
| `auth_token` | string | no | Device-linked provider token from `darkbloom login` |
| `private_only` | bool | no | `true` ⇒ only owner's self-route requests |
| `apns_device_token` / `apns_environment` | string | no | APNs code-identity attestation (v0.6.0+) |
| `python_hash` / `runtime_hash` | string | no | Runtime integrity hashes |
| `template_hashes` | object | no | `name → SHA-256` |
| `privacy_capabilities` | object | no | [`PrivacyCapabilities`](#privacycapabilities) |

### `heartbeat`

Go: [`HeartbeatMessage`](../../coordinator/protocol/messages.go); Swift: `ProviderMessage.Heartbeat`.

| Field | Type | Notes |
|---|---|---|
| `type` | string | `"heartbeat"` |
| `status` | string | Provider status string |
| `active_model` | string / null | Currently loaded model id; `null` means none loaded |
| `stats` | object | `requests_served`, `tokens_generated`, cancel/error counters, plus the [profiler counters](#profiler-counters-in-stats) below |
| `warm_models` | array | Models currently resident in GPU memory |
| `system_metrics` | object | `memory_pressure`, `cpu_usage`, `thermal_state` |
| `backend_capacity` | object / null | [`BackendCapacity`](#backendcapacity); nil for legacy providers |

#### Profiler counters in `stats`

Go: `HeartbeatStats` in [`messages.go`](../../coordinator/protocol/messages.go). Cumulative per provider session and delta-merged like the counters above; omitted when zero and absent on providers that predate them. A non-monotonic value is flagged, never rejected.

| Field | Type | Notes |
|---|---|---|
| `cancel_stage_pre_accept_total` | integer | Cancels received before the `inference_accepted` frame was sent |
| `cancel_stage_pre_engine_total` | integer | Cancels received after accept, before engine submit |
| `cancel_stage_prefill_total` | integer | Cancels received during prefill (no first token yet) |
| `cancel_stage_decode_total` | integer | Cancels received during decode |
| `cancel_stage_post_terminal_total` | integer | Cancels that arrived after the terminal frame |
| `tokens_after_cancel_total` | integer | Tokens the engine still produced after a cancel was received |
| `cancel_abort_ns_sum` | integer | Σ cancel-receipt → engine-abort latency, nanoseconds |

### `inference_accepted`

Go: [`InferenceAcceptedMessage`](../../coordinator/protocol/messages.go).

| Field | Type |
|---|---|
| `type` | `"inference_accepted"` |
| `request_id` | string |

### `inference_response_chunk`

Go: [`InferenceResponseChunkMessage`](../../coordinator/protocol/messages.go); Swift: `ProviderMessage.InferenceResponseChunk`.

| Field | Type | Notes |
|---|---|---|
| `type` | `"inference_response_chunk"` |
| `request_id` | string | |
| `data` | string | SSE chunk (plaintext) |
| `encrypted_data` | object | [`EncryptedPayload`](#encryptedpayload) when E2E active |

### `inference_complete`

Go: [`InferenceCompleteMessage`](../../coordinator/protocol/messages.go); Swift: `ProviderMessage.InferenceComplete`.

| Field | Type | Notes |
|---|---|---|
| `type` | `"inference_complete"` |
| `request_id` | string | |
| `usage` | object | [`UsageInfo`](#usageinfo) |
| `se_signature` | string | SE-signed response hash |
| `response_hash` | string | SHA-256 of response data |
| `profile` | object, optional | [`InferenceProfile`](#inferenceprofile), ≤ 4096 bytes, carried as raw JSON; see [System profiler objects](#system-profiler-objects) |

### `inference_error`

Go: [`InferenceErrorMessage`](../../coordinator/protocol/messages.go); Swift: `ProviderMessage.InferenceError`.

| Field | Type |
|---|---|
| `type` | `"inference_error"` |
| `request_id` | string |
| `error` | string |
| `status_code` | integer |
| `profile` | object, optional: [`InferenceProfile`](#inferenceprofile) of the failed attempt; passes through the error sanitizer as an opaque byte copy |

### `attestation_response`

Go: [`AttestationResponseMessage`](../../coordinator/protocol/messages.go); Swift: `ProviderMessage.AttestationResponse`.

| Field | Type | Notes |
|---|---|---|
| `type` | `"attestation_response"` |
| `nonce` | string | Echoed challenge nonce |
| `signature` | string | Base64 signature of `nonce+timestamp` |
| `status_signature` | string | Base64 signature of canonical status JSON (v0.3.11+) |
| `public_key` | string | Base64 X25519 public key |
| `hypervisor_active` | bool / null | Legacy: hardcoded-`false` stub, no longer sent by current providers; accepted in older providers' signed payloads for verification compat only |
| `rdma_disabled` | bool / null | |
| `sip_enabled` | bool / null | |
| `secure_boot_enabled` | bool / null | |
| `binary_hash` | string | SHA-256 of provider binary |
| `active_model_hash` | string | SHA-256 weight fingerprint of loaded model |
| `python_hash` / `runtime_hash` | string | Fresh runtime hashes |
| `template_hashes` | object | `name → SHA-256` |
| `model_hashes` | object | `model_id → SHA-256` for all active models |

### `code_attestation_response`

Reply to the APNs-delivered code-identity challenge. Go: [`CodeAttestationResponseMessage`](../../coordinator/protocol/messages.go); Swift: `ProviderMessage.CodeAttestationResponse`.

| Field | Type |
|---|---|
| `type` | `"code_attestation_response"` |
| `nonce` | string | Decrypted nonce |
| `signature` | string | SE P-256 signature over nonce bytes |

### `load_model_status`

Go: [`LoadModelStatusMessage`](../../coordinator/protocol/messages.go); Swift: `ProviderMessage.LoadModelStatus`.

| Field | Type | Notes |
|---|---|---|
| `type` | `"load_model_status"` |
| `model_id` | string | |
| `status` | string | `started`, `succeeded`, `failed` |
| `error` | string | Human-readable reason on failure |

The well-known transient error `"provider draining for update"` is matched by the coordinator for short retry backoffs ([`messages.go:66-73`](../../coordinator/protocol/messages.go)).

### `prefetch_model_status`

Go: [`PrefetchModelStatusMessage`](../../coordinator/protocol/messages.go); Swift: `ProviderMessage.PrefetchModelStatus`.

| Field | Type | Notes |
|---|---|---|
| `type` | `"prefetch_model_status"` |
| `model_id` | string | |
| `status` | string | `started`, `downloading`, `verified`, `failed` |
| `bytes_done` | integer | Best-effort progress |
| `bytes_total` | integer | Best-effort total |
| `error` | string | Failure reason |

### `models_update`

Authoritative out-of-band update to advertised model inventory after a prefetch is verified on disk. Go: [`ModelsUpdateMessage`](../../coordinator/protocol/messages.go); Swift: `ProviderMessage.ModelsUpdate`.

| Field | Type |
|---|---|
| `type` | `"models_update"` |
| `models` | array | [`ModelInfo`](#modelinfo) list |

## Coordinator → Provider messages

### `inference_request`

Go: [`InferenceRequestMessage`](../../coordinator/protocol/messages.go); Swift: `CoordinatorMessage.InferenceRequest`.

| Field | Type | Notes |
|---|---|---|
| `type` | `"inference_request"` |
| `request_id` | string | UUID |
| `body` | object | Plain JSON request body (legacy / testing) |
| `encrypted_body` | object | [`EncryptedPayload`](#encryptedpayload) — mandatory when provider has a public key |

The provider-side Swift struct uses `JSONValue` for `body` and `EncryptedPayload?` for `encrypted_body`.

### `cancel`

Go: [`CancelMessage`](../../coordinator/protocol/messages.go); Swift: `CoordinatorMessage.Cancel`.

| Field | Type |
|---|---|
| `type` | `"cancel"` |
| `request_id` | string |

### `attestation_challenge`

Go: [`AttestationChallengeMessage`](../../coordinator/protocol/messages.go); Swift: `CoordinatorMessage.AttestationChallenge`.

| Field | Type |
|---|---|
| `type` | `"attestation_challenge"` |
| `nonce` | string | Base64 random 32-byte nonce |
| `timestamp` | string | ISO 8601 timestamp |

### `runtime_status`

Go: [`RuntimeStatusMessage`](../../coordinator/protocol/messages.go); Swift: `CoordinatorMessage.RuntimeStatus`.

| Field | Type |
|---|---|
| `type` | `"runtime_status"` |
| `verified` | bool |
| `mismatches` | array | [`RuntimeMismatch`](#runtimemismatch) list |

### `load_model`

Coordinator-driven eager model load. Only sent to Swift-runtime providers. Go: [`LoadModelMessage`](../../coordinator/protocol/messages.go); Swift: `CoordinatorMessage.LoadModel`.

| Field | Type |
|---|---|
| `type` | `"load_model"` |
| `model_id` | string |

### `prefetch_model`

Coordinator-driven background download + verify (no GPU load). Go: [`PrefetchModelMessage`](../../coordinator/protocol/messages.go); Swift: `CoordinatorMessage.PrefetchModel`.

| Field | Type | Notes |
|---|---|---|
| `type` | `"prefetch_model"` |
| `model_id` | string | |
| `priority` | integer | Advisory ordering hint; omitted when zero |

### `desired_models`

Declarative desired-state map sent after register and on alias changes. Only sent to Swift providers ≥ v0.5.17. Go: [`DesiredModelsMessage`](../../coordinator/protocol/messages.go); Swift: `CoordinatorMessage.DesiredModels`.

| Field | Type | Notes |
|---|---|---|
| `type` | `"desired_models"` |
| `models` | array | [`DesiredModelEntry`](#desiredmodelentry) list |

#### `DesiredModelEntry`

| Field | Type | Notes |
|---|---|---|
| `model_name` | string | Public alias, e.g. `gemma-4-26b` |
| `desired_build` | string | Concrete build id to converge to |
| `previous_build` | string | Still-acceptable build during rollout |

### `trust_status`

Go: [`TrustStatusMessage`](../../coordinator/protocol/messages.go); Swift: `CoordinatorMessage.TrustStatus`.

| Field | Type | Notes |
|---|---|---|
| `type` | `"trust_status"` |
| `trust_level` | string | `none`, `self_signed`, `hardware` |
| `status` | string | `online`, `untrusted`, etc. |
| `reason` | string | Optional reason |

## Shared structs

### `Hardware`

Go: [`Hardware`](../../coordinator/protocol/messages.go); Swift: `HardwareInfo`.

| Field | Type |
|---|---|
| `machine_model` | string |
| `chip_name` | string |
| `chip_family` | string |
| `chip_tier` | string |
| `memory_gb` | integer |
| `memory_available_gb` | number |
| `cpu_cores` | object | `total`, `performance`, `efficiency` |
| `gpu_cores` | integer |
| `memory_bandwidth_gbs` | number |

### `ModelInfo`

Go: [`ModelInfo`](../../coordinator/protocol/messages.go); Swift: `ModelInfo`.

| Field | Type | Notes |
|---|---|---|
| `id` | string | Model id |
| `size_bytes` | integer | |
| `model_type` | string | |
| `quantization` | string | |
| `weight_hash` | string | SHA-256 fingerprint of weight files; optional |
| `is_vision` | bool | Only emitted when `true`; pre-0.6.0 providers omit |
| `template_render_ok` | bool / null | `false` excludes provider from tool requests; `null` omitted |

Swift's `ModelInfo` additionally carries `estimated_memory_gb` and `parameters` for local use; they are not sent to the coordinator.

### `BackendCapacity`

Go: [`BackendCapacity`](../../coordinator/protocol/messages.go); Swift: `BackendCapacity`.

| Field | Type |
|---|---|
| `slots` | array | [`BackendSlotCapacity`](#backendslotcapacity) |
| `gpu_memory_active_gb` | number |
| `gpu_memory_peak_gb` | number |
| `gpu_memory_cache_gb` | number |
| `total_memory_gb` | number |
| `free_for_load_gb` | number, optional |
| `mlx_cache_reclaimer` | [`MLXCacheReclaimerTelemetry`](#mlxcachereclaimertelemetry), optional |
| `telemetry` | [`CapacityTelemetry`](#capacitytelemetry), optional |

### `MLXCacheReclaimerTelemetry`

Allocator telemetry carried by instrumented providers. Counters are cumulative
for one provider process and reset on restart; older providers omit the object.

Canonical wire definitions: `coordinator/protocol/messages.go:363-394` and
`provider-swift/Sources/ProviderCore/Protocol/Types.swift:707-802`.

| Field | Type | Notes |
|---|---|---|
| `cache_limit_bytes` | integer | Configured MLX reusable-buffer cache ceiling |
| `sweep_signals` | integer | Periodic proactive sweep signals received |
| `reclaims` | integer | `clearCache()` operations actually performed |
| `reclaimed_bytes` | integer | Cumulative observed cache reduction |
| `last_reclaimed_bytes` | integer | Observed reduction around the latest reclaim |
| `last_reclaim_duration_ms` | integer | Blocking synchronize + clear duration |

The coordinator publishes these heartbeat values as Datadog gauges under
`provider.mlx_memory.*` and `provider.mlx_cache.*`, tagged by `provider_id`
(`coordinator/api/provider_mlx_cache_telemetry.go:13-32`).

### `BackendSlotCapacity`

Go: [`BackendSlotCapacity`](../../coordinator/protocol/messages.go); Swift: `BackendSlotCapacity`.

| Field | Type | Notes |
|---|---|---|
| `model` | string | |
| `state` | string | `running`, `idle` (loaded, no active requests), `idle_shutdown`, `crashed`, `reloading` |
| `num_running` | integer | |
| `num_waiting` | integer | |
| `max_concurrency` | integer | Optional provider-reported cap |
| `active_tokens` | integer | |
| `max_tokens_potential` | integer | |
| `observed_decode_tps` | number | EWMA decode TPS |
| `active_token_budget_used` | integer | |
| `active_token_budget_max` | integer | |
| `queued_token_budget` | integer | |
| `kv_bytes_per_token` | integer | Provider-side only |
| `telemetry` | object, optional | [`SlotTelemetry`](#slottelemetry); presence marks a profiler-aware provider |

`"idle"` means the model **is loaded**; treat it as warm for routing decisions.

### `EncryptedPayload`

Go: [`EncryptedPayload`](../../coordinator/protocol/messages.go); Swift: `EncryptedPayload`.

| Field | Type |
|---|---|
| `ephemeral_public_key` | string | Base64 X25519 public key |
| `ciphertext` | string | Base64 `nonce || encrypted data` |

### `UsageInfo`

Go: [`UsageInfo`](../../coordinator/protocol/messages.go); Swift: `UsageInfo`.

| Field | Type | Notes |
|---|---|---|
| `prompt_tokens` | integer | |
| `completion_tokens` | integer | |
| `reasoning_tokens` | integer | Subset of `completion_tokens`; omitted when zero |

### `RuntimeMismatch`

Go: [`RuntimeMismatch`](../../coordinator/protocol/messages.go); Swift: `RuntimeMismatch`.

| Field | Type |
|---|---|
| `component` | string |
| `expected` | string |
| `got` | string |

### `PrivacyCapabilities`

Go: [`PrivacyCapabilities`](../../coordinator/protocol/messages.go); Swift: `PrivacyCapabilities`.

| Field | Type |
|---|---|
| `text_backend_inprocess` | bool |
| `text_proxy_disabled` | bool |
| `python_runtime_locked` | bool |
| `dangerous_modules_blocked` | bool |
| `sip_enabled` | bool |
| `anti_debug_enabled` | bool |
| `core_dumps_disabled` | bool |
| `env_scrubbed` | bool |

## System profiler objects

Go: [`coordinator/protocol/profile.go`](../../coordinator/protocol/profile.go); Swift: [`provider-swift/Sources/ProviderCore/Protocol/InferenceProfile.swift`](../../provider-swift/Sources/ProviderCore/Protocol/InferenceProfile.swift). Design and ingestion rules: [`docs/architecture/system-profiler.md`](../architecture/system-profiler.md) §6. All three objects are measurement only: nothing in them influences routing, health, billing, deadlines or client output.

Mixed-fleet rule:

- Every field is optional (`omitempty` / `encodeIfPresent`). An absent object means an older provider. Inside a present `profile`, an absent numeric means "did not happen" or unknown and is never read as `0`; inside a present `telemetry` object an absent numeric reads as `0`.
- Every string field is a closed enum. The coordinator folds an unknown value to `other` (counted, never rejected); the Swift decoder does the same.
- `profile` is carried as raw JSON (Go `json.RawMessage`), so its contents can never fail the envelope decode of a terminal frame. The WebSocket read loop only checks its length (> 4096 bytes drops the profile with reason `size`); decode, `schema`, range and order validation run later on the profile sink worker and can only mark the profile invalid (`decode`, `schema`, `range`, `order`). The terminal is processed identically either way.
- Two-way sync: a key added to `profile.go` must be added to `InferenceProfile.swift` in the same change, and vice versa. The shared fixture [`coordinator/protocol/testdata/profiler_wire_fixture.json`](../../coordinator/protocol/testdata/profiler_wire_fixture.json) is written by Go and loaded by Swift; both sides assert the key sets. Unlike telemetry events there is no TypeScript mirror and no allowlist.

### `InferenceProfile`

`profile` on `inference_complete` / `inference_error`. Offsets are microseconds from `t0p` = WebSocket frame receipt on the provider's `SuspendingClock`; durations are microseconds; the `engine` sub-object is nanoseconds from engine enqueue (`DispatchTime`). Never subtract across the two domains. Accepted ranges: `_us` ∈ [0, 3.6e9], `_ns` ∈ [0, 3.6e12], counts ∈ [0, 1e9], bytes ∈ [0, 2^48], `wall_ms` within 24 h of receipt; anything outside is clamped and the profile is marked `range`.

| Group | Keys |
|---|---|
| Header | `schema` (must be `1`), `wall_ms` (untrusted wall-clock anchor, Unix ms) |
| Offsets (µs from `t0p`) | `dequeued_us`, `decrypted_us`, `parsed_us`, `admission_us`, `accepted_sent_us`, `load_wait_start_us`, `load_wait_end_us`, `task_spawned_us`, `prompt_prep_start_us`, `prompt_prep_end_us`, `engine_submit_us`, `engine_admitted_us`, `first_delta_us`, `first_frame_us`, `last_delta_us`, `terminal_built_us`, `terminal_sent_us`, `cancel_received_us`, `cancel_aborted_us`, `total_us` |
| Durations (µs) | `tool_constraint_us`, `vision_prep_us`, `ssd_stage_us`, `kv_reserve_us`, `flush_us`, `se_sign_us`, `slept_us`, `projected_service_us`, `budget_remaining_at_admit_us` |
| Counts | `prompt_tokens`, `frames_emitted`, `running_at_admit`, `waiting_at_admit`, `queued_prefill_tokens_at_admit`, `steps_at_submit`, `steps_at_finish`, `projected_prefill_tokens`, `projected_decode_tokens`, `partial_prefill_cap`, `tokens_after_cancel` |
| Bytes | `bytes_emitted`, `kv_bytes_in_use_at_admit`, `kv_bytes_capacity`, `mlx_active_bytes_at_finish`, `mlx_peak_bytes` |
| Flags (bool) | `usage_recovered`, `load_cold`, `load_parked`, `mtp_active`, `low_power_mode` |
| Enums | `deadline_mode` ∈ {`none`, `projected`, `legacy`, `other`}; `thermal_state` ∈ {`nominal`, `fair`, `serious`, `critical`, `other`}; `cancel_stage` ∈ {`none`, `pre_accept`, `pre_engine`, `prefill`, `decode`, `post_terminal`, `other`} |
| `engine` (object, optional) | Stamps (ns): `admitted_ns`, `kv_allocated_ns`, `prefill_first_launch_ns`, `prompt_computed_ns`, `first_token_ns`, `finished_ns`. Counts: `readmissions`, `preemptions`, `capacity_requeues`, `prefill_chunks`, `packed_prefill_chunks`, `vision_chunks`, `solo_stripe_chunks`, `prefill_chunk_tokens_max`, `decode_steps`, `chained_decode_steps`, `batch_rows_sum`, `batch_rows_min`, `batch_rows_max`, `mtp_rounds`, `mtp_proposed`, `mtp_accepted`, `pause_count`. Durations (ns): `step_latency_ns_sum`, `step_latency_ns_max`, `paused_ns`, `detok_delay_first_ns`, `prefix_lookup_ns`, `prefix_adoption_ns`. Enum: `finish_reason` ∈ {`stop`, `length`, `stop_sequence`, `cancelled`, `error`, `other`} |

Order invariants over the stamps that are present (a violation marks the profile `order`): `dequeued ≤ decrypted ≤ parsed ≤ admission ≤ engine_submit ≤ engine_admitted ≤ first_delta ≤ last_delta ≤ terminal_built ≤ terminal_sent ≤ total`; `load_wait_start ≤ load_wait_end`; `prompt_prep_start ≤ prompt_prep_end`; `cancel_received ≤ cancel_aborted`; `steps_at_submit ≤ steps_at_finish`; engine `admitted ≤ kv_allocated ≤ prefill_first_launch ≤ prompt_computed ≤ first_token ≤ finished`, `mtp_accepted ≤ mtp_proposed`, `batch_rows_min ≤ batch_rows_max`, `step_latency_ns_max ≤ step_latency_ns_sum`.

### `SlotTelemetry`

`telemetry` on [`BackendSlotCapacity`](#backendslotcapacity). Sent on every heartbeat by profiler-aware providers, possibly sparse. Clamped silently in `registry.clampBackendCapacity` (negative → `0`; counts ≤ 1e12, bytes ≤ 2^48, `eval_in_flight_ms` ≤ 3.6e6, `step_wall_ns_total` ≤ 1e18, `isolated_prefill_tps` ≤ 20000 with NaN/Inf dropped as unreported).

| Field | Type | Notes |
|---|---|---|
| `queued_prefill_tokens` | integer | Σ prompt tokens of requests whose engine submit has not returned |
| `partial_prefill_rows` | integer | Admitted rows with no first token yet |
| `prefill_tokens_total` | integer | Cumulative Σ(prompt − cached) tokens over finished requests |
| `isolated_prefill_tps` | number | Isolated prefill throughput EWMA; `0` until `ewma_initialized` |
| `ewma_initialized` | bool | Whether `isolated_prefill_tps` has a sample |
| `pump_tasks` | integer | Live stream-pump tasks on the slot |
| `mtp_rounds_total`, `mtp_proposed_total`, `mtp_accepted_total` | integer | Cumulative MTP rounds / proposed / accepted draft tokens |
| `kv_bytes_in_use` | integer | `CBv2CapacitySnapshot.kvBytesInUse`, raw bytes |
| `kv_bytes_capacity` | integer | `CBv2CapacitySnapshot.kvBytesCapacity` (admission ledger) bounded by `kvBytesBackendCapacity` when that is known, raw bytes |
| `eval_in_flight_ms` | integer | Same `EvalProbe.currentEvalElapsedMs` read as the slot-level `eval_in_flight_ms`: ms the current blocking eval has run, process-global |
| `step_wall_ns_total` | integer | Cumulative engine step wall time, ns |
| `decode_rows_total` | integer | Cumulative decode rows stepped |

### `CapacityTelemetry`

`telemetry` on [`BackendCapacity`](#backendcapacity). Same presence and clamp rules as `SlotTelemetry` (counts ≤ 1e12; `memory_pressure_level` folded to `other`).

| Field | Type | Notes |
|---|---|---|
| `low_power_mode` | bool | `ProcessInfo.isLowPowerModeEnabled` at heartbeat time |
| `memory_pressure_level` | string | `normal`, `warning`, `critical`, `other`: last kernel level seen by `MemoryPressureMonitor` |
| `mlx_num_resources` | integer | `MLX.Memory.numResources` (live MLX buffers) |
| `in_admission` | integer | Coordinator requests accepted but not yet finished |
| `inflight_tasks` | integer | Detached inference tasks registered |
