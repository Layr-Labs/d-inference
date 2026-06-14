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
| `stats` | object | `requests_served`, `tokens_generated` |
| `warm_models` | array | Models currently resident in GPU memory |
| `system_metrics` | object | `memory_pressure`, `cpu_usage`, `thermal_state` |
| `backend_capacity` | object / null | [`BackendCapacity`](#backendcapacity); nil for legacy providers |

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

### `inference_error`

Go: [`InferenceErrorMessage`](../../coordinator/protocol/messages.go); Swift: `ProviderMessage.InferenceError`.

| Field | Type |
|---|---|
| `type` | `"inference_error"` |
| `request_id` | string |
| `error` | string |
| `status_code` | integer |

### `attestation_response`

Go: [`AttestationResponseMessage`](../../coordinator/protocol/messages.go); Swift: `ProviderMessage.AttestationResponse`.

| Field | Type | Notes |
|---|---|---|
| `type` | `"attestation_response"` |
| `nonce` | string | Echoed challenge nonce |
| `signature` | string | Base64 signature of `nonce+timestamp` |
| `status_signature` | string | Base64 signature of canonical status JSON (v0.3.11+) |
| `public_key` | string | Base64 X25519 public key |
| `hypervisor_active` | bool / null | |
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
| `hypervisor_active` | bool |
