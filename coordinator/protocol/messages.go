// Package protocol defines the wire protocol message types shared between
// the coordinator and provider agents.
//
// All WebSocket messages are JSON with a "type" field used as a discriminator
// to determine which concrete struct to unmarshal into. This is a simple
// tagged union pattern.
//
// Message flow:
//
//	Provider → Coordinator: register, heartbeat, inference_response_chunk,
//	                        inference_complete, inference_error, attestation_response
//	Coordinator → Provider: inference_request, cancel, attestation_challenge
//
// Inference requests may be carried either as plain JSON in Body or as an
// X25519/NaCl-box encrypted payload in EncryptedBody. The coordinator can
// decrypt sender-sealed requests inside its Confidential VM for routing, then
// re-encrypts to the provider before dispatch. The provider is attested via
// Secure Enclave challenge-response.
package protocol

import (
	"encoding/json"
	"fmt"
)

// NOTE: json.RawMessage is used for the Attestation field to preserve
// the exact bytes from the provider for signature verification.

// Message type constants.
const (
	// Provider → Coordinator.
	TypeRegister               = "register"
	TypeHeartbeat              = "heartbeat"
	TypeInferenceAccepted      = "inference_accepted"
	TypeInferenceResponseChunk = "inference_response_chunk"
	TypeInferenceComplete      = "inference_complete"
	TypeInferenceError         = "inference_error"
	TypeAttestationResponse    = "attestation_response"
	// TypeCodeAttestationResponse is the provider's reply to the APNs-delivered
	// code-identity challenge (E_K(nonce) push). Distinct from the liveness
	// attestation_response: this is the WebSocket return leg of the push round-trip.
	TypeCodeAttestationResponse = "code_attestation_response"
	TypeLoadModelStatus         = "load_model_status"
	TypePrefetchModelStatus     = "prefetch_model_status"
	TypeModelsUpdate            = "models_update"

	// Coordinator → Provider.
	TypeInferenceRequest     = "inference_request"
	TypeCancel               = "cancel"
	TypeAttestationChallenge = "attestation_challenge"
	TypeRuntimeStatus        = "runtime_status"
	TypeLoadModel            = "load_model"
	TypePrefetchModel        = "prefetch_model"
	TypeDesiredModels        = "desired_models"
	TypeTrustStatus          = "trust_status"
)

// LoadModelStatus is the lifecycle state reported by a provider in response
// to a LoadModelMessage.
const (
	LoadModelStatusStarted   = "started"
	LoadModelStatusSucceeded = "succeeded"
	LoadModelStatusFailed    = "failed"
)

// ProviderDrainingForUpdate is the well-known error reason a provider attaches
// to inference / load_model / prefetch_model rejections while it is draining
// ahead of an auto-update restart. The coordinator matches this exact string
// to treat such a load_model failure as transient (short retry backoff,
// provider is about to restart) rather than a genuine load failure that earns
// the full cooldown. Mirrored in
// provider-swift/Sources/ProviderCore/Protocol/Types.swift.
const ProviderDrainingForUpdate = "provider draining for update"

// PrefetchModelStatus is the lifecycle state reported by a provider in
// response to a PrefetchModelMessage. Unlike a load, a prefetch only
// downloads + verifies the model on disk; it does NOT load weights into
// GPU memory, so "verified" (not "succeeded") is the terminal success
// state: the build is on disk, hash-checked, and ready to be advertised.
const (
	PrefetchModelStatusStarted     = "started"
	PrefetchModelStatusDownloading = "downloading"
	PrefetchModelStatusVerified    = "verified"
	PrefetchModelStatusFailed      = "failed"
)

// ---------------------------------------------------------------------------
// Hardware / Model descriptors
// ---------------------------------------------------------------------------

// CPUCores describes the CPU core layout.
type CPUCores struct {
	Total       int `json:"total"`
	Performance int `json:"performance"`
	Efficiency  int `json:"efficiency"`
}

// Hardware describes the provider's machine capabilities.
type Hardware struct {
	MachineModel       string   `json:"machine_model"`
	ChipName           string   `json:"chip_name"`
	ChipFamily         string   `json:"chip_family"`
	ChipTier           string   `json:"chip_tier"`
	MemoryGB           int      `json:"memory_gb"`
	MemoryAvailableGB  float64  `json:"memory_available_gb"`
	CPUCores           CPUCores `json:"cpu_cores"`
	GPUCores           int      `json:"gpu_cores"`
	MemoryBandwidthGBs float64  `json:"memory_bandwidth_gbs"`
}

// ModelInfo describes a model available on a provider.
type ModelInfo struct {
	ID           string `json:"id"`
	SizeBytes    int64  `json:"size_bytes"`
	ModelType    string `json:"model_type"`
	Quantization string `json:"quantization"`
	WeightHash   string `json:"weight_hash,omitempty"` // SHA-256 fingerprint of weight files
	// IsVision is true when the provider can serve this build with image/video
	// input (a VLM, detected via vision_config). v0.6.0+ only; older providers omit
	// it (decodes to false) so they are never selected for media requests. The
	// coordinator uses this purely for routing — the public input-modalities a
	// consumer sees are governed separately by the catalog capabilities, so this
	// advertisement does not by itself light up vision in the API.
	IsVision bool `json:"is_vision,omitempty"`
}

// ---------------------------------------------------------------------------
// Provider → Coordinator messages
// ---------------------------------------------------------------------------

// RegisterMessage is sent when a provider first connects.
type RegisterMessage struct {
	Type                    string          `json:"type"`
	Hardware                Hardware        `json:"hardware"`
	Models                  []ModelInfo     `json:"models"`
	Backend                 string          `json:"backend"`
	Version                 string          `json:"version,omitempty"`                   // provider binary version (e.g. "0.2.31")
	PublicKey               string          `json:"public_key,omitempty"`                // base64-encoded X25519 public key for E2E encryption
	EncryptedResponseChunks bool            `json:"encrypted_response_chunks,omitempty"` // true when text response chunks are returned encrypted to the coordinator
	Attestation             json.RawMessage `json:"attestation,omitempty"`               // signed Secure Enclave attestation blob
	PrefillTPS              float64         `json:"prefill_tps,omitempty"`               // benchmark: prefill tokens per second
	DecodeTPS               float64         `json:"decode_tps,omitempty"`                // benchmark: decode tokens per second
	AuthToken               string          `json:"auth_token,omitempty"`                // device-linked provider token (from darkbloom login)
	PrivateOnly             bool            `json:"private_only,omitempty"`              // when true, this machine serves only its owner's self-route requests, never the public fleet

	// APNs code-identity attestation (v0.6.0): the device token the coordinator
	// pushes the E_K(nonce) code-identity challenge to, and which APNs environment
	// that token belongs to. Bound 1:1 to PublicKey (K) at registration.
	APNsDeviceToken string `json:"apns_device_token,omitempty"` // hex device token from registerForRemoteNotifications
	APNsEnvironment string `json:"apns_environment,omitempty"`  // "production" | "development" (selects the APNs host)

	// Runtime integrity hashes — used for runtime verification against known-good manifests.
	PythonHash          string               `json:"python_hash,omitempty"`     // SHA-256 of Python runtime
	RuntimeHash         string               `json:"runtime_hash,omitempty"`    // SHA-256 of inference runtime (vllm-mlx)
	TemplateHashes      map[string]string    `json:"template_hashes,omitempty"` // template_name -> SHA-256 hash
	PrivacyCapabilities *PrivacyCapabilities `json:"privacy_capabilities,omitempty"`
}

// PrivacyCapabilities describes the provider's privacy invariants at registration time.
type PrivacyCapabilities struct {
	TextBackendInprocess    bool `json:"text_backend_inprocess"`
	TextProxyDisabled       bool `json:"text_proxy_disabled"`
	PythonRuntimeLocked     bool `json:"python_runtime_locked"`
	DangerousModulesBlocked bool `json:"dangerous_modules_blocked"`
	SIPEnabled              bool `json:"sip_enabled"`
	AntiDebugEnabled        bool `json:"anti_debug_enabled"`
	CoreDumpsDisabled       bool `json:"core_dumps_disabled"`
	EnvScrubbed             bool `json:"env_scrubbed"`
	HypervisorActive        bool `json:"hypervisor_active"`
}

// HeartbeatMessage is sent periodically by connected providers.
type HeartbeatMessage struct {
	Type            string           `json:"type"`
	Status          string           `json:"status"`
	ActiveModel     *string          `json:"active_model"`
	Stats           HeartbeatStats   `json:"stats"`
	WarmModels      []string         `json:"warm_models,omitempty"`      // models currently loaded in memory
	SystemMetrics   SystemMetrics    `json:"system_metrics"`             // live resource utilization
	BackendCapacity *BackendCapacity `json:"backend_capacity,omitempty"` // live backend capacity (nil for old providers)
}

// BackendSlotCapacity describes the capacity state of a single backend slot
// (one vllm-mlx instance serving one model).
type BackendSlotCapacity struct {
	Model              string `json:"model"`                     // model ID for this slot
	State              string `json:"state"`                     // "running", "idle_shutdown", "crashed", "reloading"
	NumRunning         int    `json:"num_running"`               // requests actively generating
	NumWaiting         int    `json:"num_waiting"`               // requests queued in backend scheduler
	MaxConcurrency     int    `json:"max_concurrency,omitempty"` // provider-reported concurrent request cap for this slot
	ActiveTokens       int64  `json:"active_tokens"`             // sum of (prompt_tokens + completion_tokens) across running requests
	MaxTokensPotential int64  `json:"max_tokens_potential"`      // sum of max_tokens across running requests (worst-case growth)

	ObservedDecodeTPS     float64 `json:"observed_decode_tps,omitempty"`      // EWMA of measured per-request decode TPS
	ActiveTokenBudgetUsed int64   `json:"active_token_budget_used,omitempty"` // tokens reserved by active requests (prompt + max_output)
	ActiveTokenBudgetMax  int64   `json:"active_token_budget_max,omitempty"`  // maximum token budget for this slot
	QueuedTokenBudget     int64   `json:"queued_token_budget,omitempty"`      // tokens reserved by queued requests
	KVBytesPerToken       int64   `json:"kv_bytes_per_token,omitempty"`       // per-token KV cache memory cost in bytes (provider-side only)
}

// BackendCapacity describes the aggregate capacity across all backend slots
// on a provider. Reported in heartbeats so the coordinator can make informed
// routing decisions based on actual GPU utilization rather than hardcoded limits.
type BackendCapacity struct {
	Slots             []BackendSlotCapacity `json:"slots"`                // per-model slot capacity
	GPUMemoryActiveGB float64               `json:"gpu_memory_active_gb"` // Metal active memory (shared across all slots)
	GPUMemoryPeakGB   float64               `json:"gpu_memory_peak_gb"`   // Metal peak memory
	GPUMemoryCacheGB  float64               `json:"gpu_memory_cache_gb"`  // Metal cache memory (reclaimable)
	TotalMemoryGB     float64               `json:"total_memory_gb"`      // total system/GPU memory
}

// SystemMetrics contains live resource utilization reported by a provider.
type SystemMetrics struct {
	MemoryPressure float64 `json:"memory_pressure"` // 0.0 to 1.0
	CPUUsage       float64 `json:"cpu_usage"`       // 0.0 to 1.0
	ThermalState   string  `json:"thermal_state"`   // nominal, fair, serious, critical
}

// HeartbeatStats contains counters reported in heartbeats.
type HeartbeatStats struct {
	RequestsServed  int64 `json:"requests_served"`
	TokensGenerated int64 `json:"tokens_generated"`
}

// InferenceAcceptedMessage signals the provider accepted the request and is
// working on it (possibly reloading the backend). The coordinator extends the
// wait window to the full inference timeout, but can still retry if the
// provider fails before sending the first chunk.
type InferenceAcceptedMessage struct {
	Type      string `json:"type"`
	RequestID string `json:"request_id"`
}

// InferenceResponseChunkMessage carries a single SSE chunk from the provider.
// When E2E encryption is active, Data is empty and EncryptedData contains
// the encrypted chunk.
type InferenceResponseChunkMessage struct {
	Type          string            `json:"type"`
	RequestID     string            `json:"request_id"`
	Data          string            `json:"data,omitempty"`
	EncryptedData *EncryptedPayload `json:"encrypted_data,omitempty"`
}

// UsageInfo carries token usage information.
type UsageInfo struct {
	PromptTokens     int `json:"prompt_tokens"`
	CompletionTokens int `json:"completion_tokens"`
	// ReasoningTokens is the subset of CompletionTokens spent on
	// reasoning/analysis content (gpt-oss analysis channel, <think>
	// blocks, etc.), counted with the model tokenizer on the provider.
	// 0 when the response carried no reasoning content. Mirrors
	// `reasoningTokens` in the Swift UsageInfo. omitempty keeps the wire
	// shape unchanged for non-reasoning responses and older providers.
	ReasoningTokens int `json:"reasoning_tokens,omitempty"`
}

// InferenceCompleteMessage signals the provider finished generating.
type InferenceCompleteMessage struct {
	Type         string    `json:"type"`
	RequestID    string    `json:"request_id"`
	Usage        UsageInfo `json:"usage"`
	SESignature  string    `json:"se_signature,omitempty"`  // SE-signed response hash
	ResponseHash string    `json:"response_hash,omitempty"` // SHA-256 of response data
}

// InferenceErrorMessage signals an error during inference.
type InferenceErrorMessage struct {
	Type       string `json:"type"`
	RequestID  string `json:"request_id"`
	Error      string `json:"error"`
	StatusCode int    `json:"status_code"`
}

// ---------------------------------------------------------------------------
// Coordinator → Provider messages
// ---------------------------------------------------------------------------

// ChatMessage is a single message in the OpenAI chat format.
type ChatMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// InferenceRequestBody is the body sent inside an InferenceRequest.
type InferenceRequestBody struct {
	Model       string        `json:"model"`
	Messages    []ChatMessage `json:"messages"`
	Stream      bool          `json:"stream"`
	MaxTokens   *int          `json:"max_tokens,omitempty"`
	Temperature *float64      `json:"temperature,omitempty"`
	// Endpoint is the backend path to forward to (e.g. "/v1/chat/completions",
	// "/v1/completions", "/v1/messages"). Defaults to "/v1/chat/completions"
	// if empty, for backwards compatibility.
	Endpoint string `json:"endpoint,omitempty"`
}

// InferenceRequestMessage tells a provider to run inference.
// When E2E encryption is enabled, Body is empty and EncryptedBody contains
// the NaCl Box encrypted request. Only the provider's hardened process can
// decrypt it using its X25519 private key.
type InferenceRequestMessage struct {
	Type      string               `json:"type"`
	RequestID string               `json:"request_id"`
	Body      InferenceRequestBody `json:"body,omitempty"`
	// E2E encrypted request body (set when provider has a public key)
	EncryptedBody *EncryptedPayload `json:"encrypted_body,omitempty"`
}

// EncryptedPayload carries a NaCl Box encrypted message.
type EncryptedPayload struct {
	EphemeralPublicKey string `json:"ephemeral_public_key"` // sender's ephemeral X25519 public key (base64)
	Ciphertext         string `json:"ciphertext"`           // nonce || encrypted data (base64)
}

// CancelMessage tells a provider to cancel an in-flight request.
type CancelMessage struct {
	Type      string `json:"type"`
	RequestID string `json:"request_id"`
}

// LoadModelMessage instructs a provider to eagerly load (and pin in
// GPU memory) a model that the coordinator anticipates demand for.
// Providers receive it on the existing WebSocket connection (no new
// inbound port required) and reply asynchronously with a
// LoadModelStatusMessage when the load completes or fails.
//
// This is sent only to providers running the Swift runtime
// (`backend == "mlx-swift"`); the coordinator filters by backend
// accordingly.
type LoadModelMessage struct {
	Type    string `json:"type"`
	ModelID string `json:"model_id"`
}

// LoadModelStatusMessage is the provider's reply to a LoadModelMessage.
// Status is one of LoadModelStatusStarted, LoadModelStatusSucceeded,
// LoadModelStatusFailed. On failure, Error carries a human-readable
// reason (e.g. "model not in local cache", "GPU OOM").
type LoadModelStatusMessage struct {
	Type    string `json:"type"`
	ModelID string `json:"model_id"`
	Status  string `json:"status"`
	Error   string `json:"error,omitempty"`
}

// PrefetchModelMessage instructs a provider to download AND verify a model
// build in the background WITHOUT loading it into GPU memory and without
// disrupting whatever model it is currently serving. It is the transport
// for zero-downtime model migrations: the coordinator tells a provider to
// fetch the new build ahead of time, then flips routing once the provider
// reports the build verified-on-disk.
//
// Priority is an advisory hint (higher = more urgent); the provider may use
// it to order concurrent prefetches. Sent only to Swift-runtime providers.
type PrefetchModelMessage struct {
	Type     string `json:"type"`
	ModelID  string `json:"model_id"`
	Priority int    `json:"priority,omitempty"`
}

// DesiredModelEntry declares, for one public model name (alias), the build the
// coordinator wants this provider to converge to. DesiredBuild is a single
// pointer (no weights). PreviousBuild (if set) stays acceptable to serve during
// a staggered rollout so a not-yet-swapped provider keeps serving.
type DesiredModelEntry struct {
	ModelName     string `json:"model_name"`               // clean/public alias, e.g. "gemma-4-26b"
	DesiredBuild  string `json:"desired_build"`            // concrete build id to converge to
	PreviousBuild string `json:"previous_build,omitempty"` // still-acceptable build mid-rollout
}

// DesiredModelsMessage is the coordinator's declarative statement of the desired
// build per public model name. Sent once right after register and again whenever
// a desired build changes. The provider reconciles: background-prefetch (resumable)
// any missing desired build, then hard-swap and emit models_update once verified.
//
// This is sent only to providers running the Swift runtime (backend ==
// "mlx-swift") at or above the version that understands it; the coordinator
// filters accordingly, because a pre-feature provider's strict decoder throws on
// unknown message types.
type DesiredModelsMessage struct {
	Type   string              `json:"type"`
	Models []DesiredModelEntry `json:"models"`
}

// ModelsUpdateMessage is an authoritative, out-of-band update to the provider's
// advertised model inventory. A provider sends it after a coordinator-driven
// prefetch is downloaded AND verified on disk, carrying the full ModelInfo
// (including the computed weight hash) for the newly-available build. The
// coordinator cross-checks each WeightHash against the catalog before merging,
// so a verified build becomes routable immediately — without the disruption of
// a full re-register (which would reset reputation and restart the challenge
// loop) and without bypassing weight-hash verification.
type ModelsUpdateMessage struct {
	Type   string      `json:"type"`
	Models []ModelInfo `json:"models"`
}

// PrefetchModelStatusMessage is the provider's progress/terminal reply to a
// PrefetchModelMessage. Status is one of PrefetchModelStatusStarted,
// PrefetchModelStatusDownloading, PrefetchModelStatusVerified,
// PrefetchModelStatusFailed. BytesDone/BytesTotal report download progress
// (best-effort; may be 0 when unknown). On failure, Error carries a
// human-readable reason.
type PrefetchModelStatusMessage struct {
	Type       string `json:"type"`
	ModelID    string `json:"model_id"`
	Status     string `json:"status"`
	BytesDone  int64  `json:"bytes_done,omitempty"`
	BytesTotal int64  `json:"bytes_total,omitempty"`
	Error      string `json:"error,omitempty"`
}

// AttestationChallengeMessage is sent by the coordinator to challenge a provider
// to prove it still holds its private key.
type AttestationChallengeMessage struct {
	Type      string `json:"type"`
	Nonce     string `json:"nonce"`     // base64-encoded random 32-byte nonce
	Timestamp string `json:"timestamp"` // ISO 8601 timestamp
}

// AttestationResponseMessage is sent by the provider in response to an
// attestation challenge. The Signature field covers nonce + timestamp only;
// it proves the responder still holds the SE key. Status fields below
// (SIPEnabled, BinaryHash, etc.) are NOT covered by Signature and would be
// trivially forgeable if used in isolation.
//
// StatusSignature (added in v0.3.11) covers a canonical JSON of nonce +
// timestamp + all status fields, sealing them against tampering. New
// providers send both signatures; old providers send only Signature, in
// which case the status fields are treated as advisory (not a basis for
// trust upgrades).
type AttestationResponseMessage struct {
	Type              string `json:"type"`
	Nonce             string `json:"nonce"`                         // echoed back from the challenge
	Signature         string `json:"signature"`                     // base64-encoded signature of nonce+timestamp
	StatusSignature   string `json:"status_signature,omitempty"`    // base64-encoded signature of canonical status JSON (see attestation.BuildStatusCanonical)
	PublicKey         string `json:"public_key"`                    // base64-encoded public key
	HypervisorActive  *bool  `json:"hypervisor_active,omitempty"`   // reported hypervisor containment status, if any
	RDMADisabled      *bool  `json:"rdma_disabled,omitempty"`       // fresh RDMA status (true = disabled, false = enabled)
	SIPEnabled        *bool  `json:"sip_enabled,omitempty"`         // fresh SIP status at challenge time
	SecureBootEnabled *bool  `json:"secure_boot_enabled,omitempty"` // fresh Secure Boot status
	BinaryHash        string `json:"binary_hash,omitempty"`         // fresh SHA-256 of provider binary
	ActiveModelHash   string `json:"active_model_hash,omitempty"`   // SHA-256 weight fingerprint of loaded model

	// Runtime integrity hashes — fresh values reported at challenge time.
	PythonHash     string            `json:"python_hash,omitempty"`     // SHA-256 of Python runtime
	RuntimeHash    string            `json:"runtime_hash,omitempty"`    // SHA-256 of inference runtime (vllm-mlx)
	TemplateHashes map[string]string `json:"template_hashes,omitempty"` // template_name -> SHA-256 hash
	ModelHashes    map[string]string `json:"model_hashes,omitempty"`    // model_id -> SHA-256 weight hash (all active models)
}

// CodeAttestationResponseMessage is the provider's reply to the APNs-delivered
// code-identity challenge. The coordinator pushed E_K(nonce) (a nonce encrypted
// to the provider's registered X25519 key K) over APNs; only our genuine,
// Apple-provisioned binary can receive that push, and only the genuine process
// can decrypt it with K. The provider returns:
//   - Nonce:     the DECRYPTED nonce (proves it could decrypt E_K(nonce) ⟹ holds K)
//   - Signature: Sign_SE(nonce) from the persistent Secure-Enclave P-256 key
//     (proves it holds the SE identity bound to K at registration)
//
// Note: K is X25519 (decrypt-only); the signature comes from the separate SE key.
// The coordinator verifies Nonce == the nonce it pushed, and Signature against
// the SE public key bound to this connection at registration — never a key
// supplied in this message. This binds the Apple-gated push proof onto THIS
// WebSocket connection.
type CodeAttestationResponseMessage struct {
	Type      string `json:"type"`
	Nonce     string `json:"nonce"`     // decrypted challenge nonce, base64 (must equal the pushed nonce)
	Signature string `json:"signature"` // base64 SE-key (P-256) signature over the nonce bytes
}

// ---------------------------------------------------------------------------
// Runtime verification messages
// ---------------------------------------------------------------------------

// RuntimeStatusMessage is sent by the coordinator to inform a provider about
// the result of its runtime integrity verification. If mismatches are found,
// the provider can self-heal (e.g. re-download corrupted files).
type RuntimeStatusMessage struct {
	Type       string            `json:"type"`
	Verified   bool              `json:"verified"`
	Mismatches []RuntimeMismatch `json:"mismatches,omitempty"`
}

// RuntimeMismatch describes a single component whose hash did not match
// the coordinator's known-good manifest.
type RuntimeMismatch struct {
	Component string `json:"component"`
	Expected  string `json:"expected"`
	Got       string `json:"got"`
}

// TrustStatusMessage is sent by the coordinator to inform a provider of its
// current trust level. Providers that learn they are "self_signed" or
// "untrusted" can auto-report unified logs for troubleshooting.
type TrustStatusMessage struct {
	Type       string `json:"type"`
	TrustLevel string `json:"trust_level"` // "none", "self_signed", "hardware"
	Status     string `json:"status"`      // "online", "untrusted", etc.
	Reason     string `json:"reason,omitempty"`
}

// ---------------------------------------------------------------------------
// Envelope: generic unmarshalling for provider messages
// ---------------------------------------------------------------------------

// ProviderMessage is an envelope that can hold any provider→coordinator message.
// Use UnmarshalJSON to decode the concrete type based on the "type" field.
type ProviderMessage struct {
	Type    string
	Payload any // one of: *RegisterMessage, *HeartbeatMessage, etc.
}

// UnmarshalJSON reads the "type" field first, then unmarshals the full object
// into the appropriate concrete struct.
func (pm *ProviderMessage) UnmarshalJSON(data []byte) error {
	var envelope struct {
		Type string `json:"type"`
	}
	if err := json.Unmarshal(data, &envelope); err != nil {
		return fmt.Errorf("protocol: failed to read message type: %w", err)
	}
	pm.Type = envelope.Type

	switch envelope.Type {
	case TypeRegister:
		var msg RegisterMessage
		if err := json.Unmarshal(data, &msg); err != nil {
			return fmt.Errorf("protocol: failed to unmarshal register: %w", err)
		}
		pm.Payload = &msg

	case TypeHeartbeat:
		var msg HeartbeatMessage
		if err := json.Unmarshal(data, &msg); err != nil {
			return fmt.Errorf("protocol: failed to unmarshal heartbeat: %w", err)
		}
		pm.Payload = &msg

	case TypeInferenceAccepted:
		var msg InferenceAcceptedMessage
		if err := json.Unmarshal(data, &msg); err != nil {
			return fmt.Errorf("protocol: failed to unmarshal inference_accepted: %w", err)
		}
		pm.Payload = &msg

	case TypeInferenceResponseChunk:
		var msg InferenceResponseChunkMessage
		if err := json.Unmarshal(data, &msg); err != nil {
			return fmt.Errorf("protocol: failed to unmarshal inference_response_chunk: %w", err)
		}
		pm.Payload = &msg

	case TypeInferenceComplete:
		var msg InferenceCompleteMessage
		if err := json.Unmarshal(data, &msg); err != nil {
			return fmt.Errorf("protocol: failed to unmarshal inference_complete: %w", err)
		}
		pm.Payload = &msg

	case TypeInferenceError:
		var msg InferenceErrorMessage
		if err := json.Unmarshal(data, &msg); err != nil {
			return fmt.Errorf("protocol: failed to unmarshal inference_error: %w", err)
		}
		pm.Payload = &msg

	case TypeAttestationResponse:
		var msg AttestationResponseMessage
		if err := json.Unmarshal(data, &msg); err != nil {
			return fmt.Errorf("protocol: failed to unmarshal attestation_response: %w", err)
		}
		pm.Payload = &msg

	case TypeCodeAttestationResponse:
		var msg CodeAttestationResponseMessage
		if err := json.Unmarshal(data, &msg); err != nil {
			return fmt.Errorf("protocol: failed to unmarshal code_attestation_response: %w", err)
		}
		pm.Payload = &msg

	case TypeLoadModelStatus:
		var msg LoadModelStatusMessage
		if err := json.Unmarshal(data, &msg); err != nil {
			return fmt.Errorf("protocol: failed to unmarshal load_model_status: %w", err)
		}
		pm.Payload = &msg

	case TypePrefetchModelStatus:
		var msg PrefetchModelStatusMessage
		if err := json.Unmarshal(data, &msg); err != nil {
			return fmt.Errorf("protocol: failed to unmarshal prefetch_model_status: %w", err)
		}
		pm.Payload = &msg

	case TypeModelsUpdate:
		var msg ModelsUpdateMessage
		if err := json.Unmarshal(data, &msg); err != nil {
			return fmt.Errorf("protocol: failed to unmarshal models_update: %w", err)
		}
		pm.Payload = &msg

	default:
		return fmt.Errorf("protocol: unknown message type %q", envelope.Type)
	}

	return nil
}
