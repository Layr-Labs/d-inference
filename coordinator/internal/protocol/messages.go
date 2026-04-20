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
// The inference request body is plain JSON (model, messages, stream). No
// encryption fields are needed in the wire protocol because the coordinator
// runs in a Confidential VM and can read requests for routing. The provider
// is attested via Secure Enclave challenge-response.
package protocol

import (
	"encoding/json"
	"fmt"
)

// NOTE: json.RawMessage is used for the Attestation field to preserve
// the exact bytes from the provider for signature verification.

// Message type constants.
const (
	// Provider → Coordinator
	TypeRegister                = "register"
	TypeHeartbeat               = "heartbeat"
	TypeInferenceAccepted       = "inference_accepted"
	TypeInferenceResponseChunk  = "inference_response_chunk"
	TypeInferenceComplete       = "inference_complete"
	TypeInferenceError          = "inference_error"
	TypeAttestationResponse     = "attestation_response"
	TypeTranscriptionComplete   = "transcription_complete"
	TypeImageGenerationComplete = "image_generation_complete"

	// Coordinator → Provider
	TypeInferenceRequest       = "inference_request"
	TypeCancel                 = "cancel"
	TypeAttestationChallenge   = "attestation_challenge"
	TypeTranscriptionRequest   = "transcription_request"
	TypeImageGenerationRequest = "image_generation_request"
	TypeRuntimeStatus          = "runtime_status"

	// Disaggregated compute (provider ↔ coordinator)
	//
	// Embedding/rerank requests are short-lived, compute-bound, and have
	// small response bodies. They route to small-tier providers (≤24 GB
	// Macs) so the big-tier fleet stays free for long-context decode.
	TypeEmbeddingRequest  = "embedding_request"
	TypeEmbeddingComplete = "embedding_complete"
	TypeRerankRequest     = "rerank_request"
	TypeRerankComplete    = "rerank_complete"
)

// ProviderTier classifies providers by hardware capability so the coordinator
// can route compute-bound, small-payload jobs to lower-RAM Macs and reserve
// big-RAM providers for memory-bandwidth-bound decode of large models.
//
// The tier is derived from advertised memory (set in the registry on
// registration) and is not reported by the provider directly — preventing
// providers from misrepresenting capability. See registry.ClassifyTier.
type ProviderTier string

const (
	// ProviderTierTiny — ≤16 GB. Useful for embeddings, reranking, and
	// future compute-bound disaggregated workloads (e.g. speculative
	// decoding draft tokens). Cannot host quality decoder LLMs.
	ProviderTierTiny ProviderTier = "tiny"
	// ProviderTierSmall — 18–24 GB. Embeddings, rerank, and small chat
	// models (≤7B). Useful as a draft model for speculative decoding.
	ProviderTierSmall ProviderTier = "small"
	// ProviderTierStandard — ≥32 GB. Full text/image/STT decode workloads.
	ProviderTierStandard ProviderTier = "standard"
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
}

// ---------------------------------------------------------------------------
// Provider → Coordinator messages
// ---------------------------------------------------------------------------

// RegisterMessage is sent when a provider first connects.
type RegisterMessage struct {
	Type          string          `json:"type"`
	Hardware      Hardware        `json:"hardware"`
	Models        []ModelInfo     `json:"models"`
	Backend       string          `json:"backend"`
	Version       string          `json:"version,omitempty"`        // provider binary version (e.g. "0.2.31")
	PublicKey     string          `json:"public_key,omitempty"`     // base64-encoded X25519 public key for E2E encryption
	WalletAddress string          `json:"wallet_address,omitempty"` // Ethereum-format hex address for Tempo payouts
	Attestation   json.RawMessage `json:"attestation,omitempty"`    // signed Secure Enclave attestation blob
	PrefillTPS    float64         `json:"prefill_tps,omitempty"`    // benchmark: prefill tokens per second
	DecodeTPS     float64         `json:"decode_tps,omitempty"`     // benchmark: decode tokens per second
	AuthToken     string          `json:"auth_token,omitempty"`     // device-linked provider token (from darkbloom login)

	// Runtime integrity hashes — used for runtime verification against known-good manifests.
	PythonHash      string            `json:"python_hash,omitempty"`       // SHA-256 of Python runtime
	RuntimeHash     string            `json:"runtime_hash,omitempty"`      // SHA-256 of inference runtime (vllm-mlx)
	TemplateHashes  map[string]string `json:"template_hashes,omitempty"`   // template_name -> SHA-256 hash
	GrpcBinaryHash  string            `json:"grpc_binary_hash,omitempty"`  // SHA-256 of gRPCServerCLI binary
	ImageBridgeHash string            `json:"image_bridge_hash,omitempty"` // SHA-256 of image bridge Python source
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
	Model              string `json:"model"`                // model ID for this slot
	State              string `json:"state"`                // "running", "idle_shutdown", "crashed", "reloading"
	NumRunning         int    `json:"num_running"`          // requests actively generating
	NumWaiting         int    `json:"num_waiting"`          // requests queued in backend scheduler
	ActiveTokens       int64  `json:"active_tokens"`        // sum of (prompt_tokens + completion_tokens) across running requests
	MaxTokensPotential int64  `json:"max_tokens_potential"` // sum of max_tokens across running requests (worst-case growth)
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
// working on it (possibly reloading the backend). The coordinator should
// commit to this provider and wait for chunks with the full inference timeout
// instead of retrying.
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

// AttestationChallengeMessage is sent by the coordinator to challenge a provider
// to prove it still holds its private key.
type AttestationChallengeMessage struct {
	Type      string `json:"type"`
	Nonce     string `json:"nonce"`     // base64-encoded random 32-byte nonce
	Timestamp string `json:"timestamp"` // ISO 8601 timestamp
}

// AttestationResponseMessage is sent by the provider in response to an
// attestation challenge. The signature covers nonce + timestamp.
// Includes fresh security posture fields verified at challenge time.
type AttestationResponseMessage struct {
	Type              string `json:"type"`
	Nonce             string `json:"nonce"`                         // echoed back from the challenge
	Signature         string `json:"signature"`                     // base64-encoded signature of nonce+timestamp
	PublicKey         string `json:"public_key"`                    // base64-encoded public key
	HypervisorActive  *bool  `json:"hypervisor_active,omitempty"`   // hypervisor memory isolation active (Stage 2 page tables)
	RDMADisabled      *bool  `json:"rdma_disabled,omitempty"`       // fresh RDMA status (true = safe, false = remote memory access possible)
	SIPEnabled        *bool  `json:"sip_enabled,omitempty"`         // fresh SIP status at challenge time
	SecureBootEnabled *bool  `json:"secure_boot_enabled,omitempty"` // fresh Secure Boot status
	BinaryHash        string `json:"binary_hash,omitempty"`         // fresh SHA-256 of provider binary
	ActiveModelHash   string `json:"active_model_hash,omitempty"`   // SHA-256 weight fingerprint of loaded model

	// Runtime integrity hashes — fresh values reported at challenge time.
	PythonHash      string            `json:"python_hash,omitempty"`       // SHA-256 of Python runtime
	RuntimeHash     string            `json:"runtime_hash,omitempty"`      // SHA-256 of inference runtime (vllm-mlx)
	TemplateHashes  map[string]string `json:"template_hashes,omitempty"`   // template_name -> SHA-256 hash
	GrpcBinaryHash  string            `json:"grpc_binary_hash,omitempty"`  // SHA-256 of gRPCServerCLI binary
	ImageBridgeHash string            `json:"image_bridge_hash,omitempty"` // SHA-256 of image bridge Python source
	ModelHashes     map[string]string `json:"model_hashes,omitempty"`      // model_id -> SHA-256 weight hash (all active models)
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

// ---------------------------------------------------------------------------
// STT (Speech-to-Text) messages
// ---------------------------------------------------------------------------

// TranscriptionRequestBody is the body sent inside a TranscriptionRequest.
type TranscriptionRequestBody struct {
	Model    string  `json:"model"`
	Audio    string  `json:"audio"`              // base64-encoded audio data
	Language *string `json:"language,omitempty"` // ISO 639-1 language code (e.g. "en")
	Format   string  `json:"format,omitempty"`   // audio format hint: "mp3", "wav", etc.
}

// TranscriptionRequestMessage tells a provider to transcribe audio.
// When E2E encryption is enabled, Body is empty and EncryptedBody contains
// the NaCl Box encrypted request (same as InferenceRequestMessage).
type TranscriptionRequestMessage struct {
	Type          string                   `json:"type"`
	RequestID     string                   `json:"request_id"`
	Body          TranscriptionRequestBody `json:"body,omitempty"`
	EncryptedBody *EncryptedPayload        `json:"encrypted_body,omitempty"`
}

// TranscriptionSegment is a timed segment within a transcription.
type TranscriptionSegment struct {
	Start float64 `json:"start"`
	End   float64 `json:"end"`
	Text  string  `json:"text"`
}

// TranscriptionUsage carries usage info for billing STT requests.
type TranscriptionUsage struct {
	AudioSeconds     float64 `json:"audio_seconds"`
	GenerationTokens int     `json:"generation_tokens"`
}

// TranscriptionCompleteMessage signals the provider finished transcribing.
type TranscriptionCompleteMessage struct {
	Type         string                 `json:"type"`
	RequestID    string                 `json:"request_id"`
	Text         string                 `json:"text"`
	Segments     []TranscriptionSegment `json:"segments,omitempty"`
	Language     string                 `json:"language,omitempty"`
	Usage        TranscriptionUsage     `json:"usage"`
	DurationSecs float64                `json:"duration_secs"` // processing time
}

// ---------------------------------------------------------------------------
// Image Generation messages
// ---------------------------------------------------------------------------

// ImageGenerationRequestBody is the body sent inside an ImageGenerationRequest.
type ImageGenerationRequestBody struct {
	Model          string `json:"model"`
	Prompt         string `json:"prompt"`
	NegativePrompt string `json:"negative_prompt,omitempty"`
	N              int    `json:"n,omitempty"`     // number of images (default 1)
	Size           string `json:"size,omitempty"`  // e.g. "1024x1024"
	Steps          *int   `json:"steps,omitempty"` // inference steps
	Seed           *int64 `json:"seed,omitempty"`
	ResponseFormat string `json:"response_format,omitempty"` // "b64_json" (default) or "url"
}

// ImageGenerationRequestMessage tells a provider to generate images.
// Includes an upload_url where the provider should POST the generated images
// via HTTP (instead of sending them over the WebSocket, which has size limits).
type ImageGenerationRequestMessage struct {
	Type          string                     `json:"type"`
	RequestID     string                     `json:"request_id"`
	UploadURL     string                     `json:"upload_url"` // HTTP endpoint for image upload
	Body          ImageGenerationRequestBody `json:"body,omitempty"`
	EncryptedBody *EncryptedPayload          `json:"encrypted_body,omitempty"`
}

// ImageGenerationUsage carries usage info for billing image generation requests.
type ImageGenerationUsage struct {
	ImagesGenerated int    `json:"images_generated"`
	Width           int    `json:"width"`
	Height          int    `json:"height"`
	Steps           int    `json:"steps"`
	Model           string `json:"model"`
}

// ImageGenerationCompleteMessage signals the provider finished generating images.
// The actual image data is uploaded separately via HTTP to the upload_url.
// This message only carries metadata so it stays small on the WebSocket.
type ImageGenerationCompleteMessage struct {
	Type         string               `json:"type"`
	RequestID    string               `json:"request_id"`
	Usage        ImageGenerationUsage `json:"usage"`
	DurationSecs float64              `json:"duration_secs"` // processing time
}

// ---------------------------------------------------------------------------
// Disaggregated compute: embeddings & reranking
//
// These workloads are compute-bound (one forward pass per input), have small
// payloads (text in, vector out), and run on models that fit in ≤2 GB. They
// are the natural target for low-RAM Mac providers that cannot host decoder
// LLMs but still have plenty of GPU compute.
// ---------------------------------------------------------------------------

// EmbeddingRequestBody is the OpenAI-compatible embedding request body
// forwarded inside an EmbeddingRequest. Input may be a single string or
// an array of strings.
type EmbeddingRequestBody struct {
	Model          string          `json:"model"`
	Input          json.RawMessage `json:"input"`                     // string or []string
	EncodingFormat string          `json:"encoding_format,omitempty"` // "float" (default) or "base64"
	Dimensions     *int            `json:"dimensions,omitempty"`      // optional truncation (Matryoshka)
	User           string          `json:"user,omitempty"`
}

// EmbeddingRequestMessage tells a small-tier provider to embed input text(s).
// Just like InferenceRequestMessage, the body is E2E-encrypted when the
// provider has a public key (the prompt is sensitive data even for embeddings).
type EmbeddingRequestMessage struct {
	Type          string               `json:"type"`
	RequestID     string               `json:"request_id"`
	Body          EmbeddingRequestBody `json:"body,omitempty"`
	EncryptedBody *EncryptedPayload    `json:"encrypted_body,omitempty"`
}

// EmbeddingVector is one input → one vector. Index matches the input order.
type EmbeddingVector struct {
	Index     int       `json:"index"`
	Embedding []float64 `json:"embedding"`
}

// EmbeddingUsage carries usage info for billing embedding requests.
// CompletionTokens is always 0 for embeddings — only prompt tokens are billed.
type EmbeddingUsage struct {
	PromptTokens int `json:"prompt_tokens"`
	TotalTokens  int `json:"total_tokens"`
}

// EmbeddingCompleteMessage carries the embedding result back to the
// coordinator. Vectors travel inline because they are small (1024–4096
// dims × 4 bytes × N inputs is well under the 10 MB WebSocket frame limit
// for typical N ≤ 64).
type EmbeddingCompleteMessage struct {
	Type         string            `json:"type"`
	RequestID    string            `json:"request_id"`
	Model        string            `json:"model"`
	Data         []EmbeddingVector `json:"data"`
	Usage        EmbeddingUsage    `json:"usage"`
	DurationSecs float64           `json:"duration_secs"`
	// EncryptedData carries the JSON-encoded `data` field encrypted with the
	// session key when E2E was used on the request. When set, Data should be
	// empty. The coordinator decrypts and forwards to the consumer.
	EncryptedData *EncryptedPayload `json:"encrypted_data,omitempty"`
}

// RerankRequestBody is the rerank request body forwarded inside a
// RerankRequest. The format mirrors Cohere's /v1/rerank API which is the
// de-facto standard for cross-encoder rerankers.
type RerankRequestBody struct {
	Model           string   `json:"model"`
	Query           string   `json:"query"`
	Documents       []string `json:"documents"`
	TopN            *int     `json:"top_n,omitempty"`            // return only top N (default: all)
	ReturnDocuments bool     `json:"return_documents,omitempty"` // echo doc text back (default: false)
}

// RerankRequestMessage tells a small-tier provider to score query↔documents.
type RerankRequestMessage struct {
	Type          string            `json:"type"`
	RequestID     string            `json:"request_id"`
	Body          RerankRequestBody `json:"body,omitempty"`
	EncryptedBody *EncryptedPayload `json:"encrypted_body,omitempty"`
}

// RerankResult is one (document, score) pair sorted descending by score.
type RerankResult struct {
	Index          int     `json:"index"`              // index into the original documents array
	RelevanceScore float64 `json:"relevance_score"`    // higher = more relevant
	Document       string  `json:"document,omitempty"` // populated only if return_documents=true
}

// RerankUsage tracks tokens scored. Each (query, document) pair counts as
// prompt tokens; rerankers do not generate completion tokens.
type RerankUsage struct {
	PromptTokens int `json:"prompt_tokens"`
	TotalTokens  int `json:"total_tokens"`
}

// RerankCompleteMessage carries scored results back to the coordinator.
type RerankCompleteMessage struct {
	Type          string            `json:"type"`
	RequestID     string            `json:"request_id"`
	Model         string            `json:"model"`
	Results       []RerankResult    `json:"results"`
	Usage         RerankUsage       `json:"usage"`
	DurationSecs  float64           `json:"duration_secs"`
	EncryptedData *EncryptedPayload `json:"encrypted_data,omitempty"`
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

	case TypeTranscriptionComplete:
		var msg TranscriptionCompleteMessage
		if err := json.Unmarshal(data, &msg); err != nil {
			return fmt.Errorf("protocol: failed to unmarshal transcription_complete: %w", err)
		}
		pm.Payload = &msg

	case TypeImageGenerationComplete:
		var msg ImageGenerationCompleteMessage
		if err := json.Unmarshal(data, &msg); err != nil {
			return fmt.Errorf("protocol: failed to unmarshal image_generation_complete: %w", err)
		}
		pm.Payload = &msg

	case TypeEmbeddingComplete:
		var msg EmbeddingCompleteMessage
		if err := json.Unmarshal(data, &msg); err != nil {
			return fmt.Errorf("protocol: failed to unmarshal embedding_complete: %w", err)
		}
		pm.Payload = &msg

	case TypeRerankComplete:
		var msg RerankCompleteMessage
		if err := json.Unmarshal(data, &msg); err != nil {
			return fmt.Errorf("protocol: failed to unmarshal rerank_complete: %w", err)
		}
		pm.Payload = &msg

	default:
		return fmt.Errorf("protocol: unknown message type %q", envelope.Type)
	}

	return nil
}
