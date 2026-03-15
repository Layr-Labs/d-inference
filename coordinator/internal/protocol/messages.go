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

	// Coordinator → Provider
	TypeInferenceRequest      = "inference_request"
	TypeCancel                = "cancel"
	TypeAttestationChallenge  = "attestation_challenge"
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
}

// HeartbeatMessage is sent periodically by connected providers.
type HeartbeatMessage struct {
	Type        string          `json:"type"`
	Status      string          `json:"status"`
	ActiveModel *string         `json:"active_model"`
	Stats       HeartbeatStats  `json:"stats"`
}

// HeartbeatStats contains counters reported in heartbeats.
type HeartbeatStats struct {
	RequestsServed  int64 `json:"requests_served"`
	TokensGenerated int64 `json:"tokens_generated"`
}

// InferenceResponseChunkMessage carries a single SSE chunk from the provider.
type InferenceResponseChunkMessage struct {
	Type      string `json:"type"`
	RequestID string `json:"request_id"`
	Data      string `json:"data"`
}

// UsageInfo carries token usage information.
type UsageInfo struct {
	PromptTokens     int `json:"prompt_tokens"`
	CompletionTokens int `json:"completion_tokens"`
}

// InferenceCompleteMessage signals the provider finished generating.
type InferenceCompleteMessage struct {
	Type      string    `json:"type"`
	RequestID string    `json:"request_id"`
	Usage     UsageInfo `json:"usage"`
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
	Model    string        `json:"model"`
	Messages []ChatMessage `json:"messages"`
	Stream   bool          `json:"stream"`
}

// InferenceRequestMessage tells a provider to run inference.
type InferenceRequestMessage struct {
	Type      string               `json:"type"`
	RequestID string               `json:"request_id"`
	Body      InferenceRequestBody `json:"body"`
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
type AttestationResponseMessage struct {
	Type      string `json:"type"`
	Nonce     string `json:"nonce"`      // echoed back from the challenge
	Signature string `json:"signature"`  // base64-encoded signature of nonce+timestamp
	PublicKey string `json:"public_key"` // base64-encoded public key
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

	default:
		return fmt.Errorf("protocol: unknown message type %q", envelope.Type)
	}

	return nil
}
