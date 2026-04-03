// Package protocol defines the wire protocol message types shared between
// the coordinator and provider agents.
//
// All WebSocket messages are JSON with a "type" field used as a discriminator
// to determine which concrete struct to unmarshal into. This is a simple
// tagged union pattern.
//
// Message flow:
//   Provider → Coordinator: register, heartbeat, inference_response_chunk,
//                           inference_complete, inference_error, attestation_response
//   Coordinator → Provider: inference_request, cancel, attestation_challenge
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
	TypeRegister              = "register"
	TypeHeartbeat             = "heartbeat"
	TypeInferenceResponseChunk = "inference_response_chunk"
	TypeInferenceComplete     = "inference_complete"
	TypeInferenceError        = "inference_error"
	TypeAttestationResponse   = "attestation_response"
	TypeTranscriptionComplete      = "transcription_complete"
	TypeImageGenerationComplete    = "image_generation_complete"

	// Coordinator → Provider
	TypeInferenceRequest           = "inference_request"
	TypeCancel                     = "cancel"
	TypeAttestationChallenge       = "attestation_challenge"
	TypeTranscriptionRequest       = "transcription_request"
	TypeImageGenerationRequest     = "image_generation_request"
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
	MachineModel       string  `json:"machine_model"`
	ChipName           string  `json:"chip_name"`
	ChipFamily         string  `json:"chip_family"`
	ChipTier           string  `json:"chip_tier"`
	MemoryGB           int     `json:"memory_gb"`
	MemoryAvailableGB  float64 `json:"memory_available_gb"`
	CPUCores           CPUCores `json:"cpu_cores"`
	GPUCores           int     `json:"gpu_cores"`
	MemoryBandwidthGBs float64 `json:"memory_bandwidth_gbs"`
}

// ModelInfo describes a model available on a provider.
type ModelInfo struct {
	ID           string `json:"id"`
	SizeBytes    int64  `json:"size_bytes"`
	ModelType    string `json:"model_type"`
	Quantization string `json:"quantization"`
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
	PublicKey     string          `json:"public_key,omitempty"`     // base64-encoded X25519 public key for E2E encryption
	WalletAddress string          `json:"wallet_address,omitempty"` // Ethereum-format hex address for Tempo payouts
	Attestation   json.RawMessage `json:"attestation,omitempty"`   // signed Secure Enclave attestation blob
	PrefillTPS    float64         `json:"prefill_tps,omitempty"`   // benchmark: prefill tokens per second
	DecodeTPS     float64         `json:"decode_tps,omitempty"`    // benchmark: decode tokens per second
	AuthToken     string          `json:"auth_token,omitempty"`    // device-linked provider token (from dginf-provider login)
}

// HeartbeatMessage is sent periodically by connected providers.
type HeartbeatMessage struct {
	Type          string          `json:"type"`
	Status        string          `json:"status"`
	ActiveModel   *string         `json:"active_model"`
	Stats         HeartbeatStats  `json:"stats"`
	WarmModels    []string        `json:"warm_models,omitempty"`           // models currently loaded in memory
	SystemMetrics SystemMetrics   `json:"system_metrics"`                   // live resource utilization
}

// SystemMetrics contains live resource utilization reported by a provider.
type SystemMetrics struct {
	MemoryPressure float64 `json:"memory_pressure"` // 0.0 to 1.0
	CPUUsage       float64 `json:"cpu_usage"`        // 0.0 to 1.0
	ThermalState   string  `json:"thermal_state"`    // nominal, fair, serious, critical
}

// HeartbeatStats contains counters reported in heartbeats.
type HeartbeatStats struct {
	RequestsServed  int64 `json:"requests_served"`
	TokensGenerated int64 `json:"tokens_generated"`
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
	Endpoint    string        `json:"endpoint,omitempty"`
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
	Nonce             string `json:"nonce"`                          // echoed back from the challenge
	Signature         string `json:"signature"`                      // base64-encoded signature of nonce+timestamp
	PublicKey         string `json:"public_key"`                     // base64-encoded public key
	HypervisorActive  *bool  `json:"hypervisor_active,omitempty"`   // hypervisor memory isolation active (Stage 2 page tables)
	RDMADisabled      *bool  `json:"rdma_disabled,omitempty"`       // fresh RDMA status (true = safe, false = remote memory access possible)
	SIPEnabled        *bool  `json:"sip_enabled,omitempty"`         // fresh SIP status at challenge time
	SecureBootEnabled *bool  `json:"secure_boot_enabled,omitempty"` // fresh Secure Boot status
}

// ---------------------------------------------------------------------------
// STT (Speech-to-Text) messages
// ---------------------------------------------------------------------------

// TranscriptionRequestBody is the body sent inside a TranscriptionRequest.
type TranscriptionRequestBody struct {
	Model    string  `json:"model"`
	Audio    string  `json:"audio"`              // base64-encoded audio data
	Language *string `json:"language,omitempty"`  // ISO 639-1 language code (e.g. "en")
	Format   string  `json:"format,omitempty"`    // audio format hint: "mp3", "wav", etc.
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
	DurationSecs float64               `json:"duration_secs"` // processing time
}

// ---------------------------------------------------------------------------
// Image Generation messages
// ---------------------------------------------------------------------------

// ImageGenerationRequestBody is the body sent inside an ImageGenerationRequest.
type ImageGenerationRequestBody struct {
	Model          string `json:"model"`
	Prompt         string `json:"prompt"`
	NegativePrompt string `json:"negative_prompt,omitempty"`
	N              int    `json:"n,omitempty"`              // number of images (default 1)
	Size           string `json:"size,omitempty"`           // e.g. "1024x1024"
	Steps          *int   `json:"steps,omitempty"`          // inference steps
	Seed           *int64 `json:"seed,omitempty"`
	ResponseFormat string `json:"response_format,omitempty"` // "b64_json" (default) or "url"
}

// ImageGenerationRequestMessage tells a provider to generate images.
// Includes an upload_url where the provider should POST the generated images
// via HTTP (instead of sending them over the WebSocket, which has size limits).
type ImageGenerationRequestMessage struct {
	Type          string                       `json:"type"`
	RequestID     string                       `json:"request_id"`
	UploadURL     string                       `json:"upload_url"`     // HTTP endpoint for image upload
	Body          ImageGenerationRequestBody   `json:"body,omitempty"`
	EncryptedBody *EncryptedPayload            `json:"encrypted_body,omitempty"`
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

	default:
		return fmt.Errorf("protocol: unknown message type %q", envelope.Type)
	}

	return nil
}
