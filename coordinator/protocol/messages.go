package protocol

import (
	"encoding/json"
	"fmt"
)

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
	TypePrefixCacheLookup       = "prefix_cache_lookup"
	TypePrefixCacheReady        = "prefix_cache_ready"
	TypePrefixCacheLookupV2     = "prefix_cache_lookup_v2"
	TypePrefixCacheReadyV2      = "prefix_cache_ready_v2"

	// TypeCapacityQuote is the provider's answer to a capacity_probe: an
	// admissibility verdict + calibrated TTFT estimate computed from its live
	// capacity snapshot. See CapacityQuoteMessage.
	TypeCapacityQuote = "capacity_quote"

	// Coordinator → Provider.
	TypeInferenceRequest               = "inference_request"
	TypeCancel                         = "cancel"
	TypeAttestationChallenge           = "attestation_challenge"
	TypeCodeAttestationResumeChallenge = "code_attestation_resume_challenge"
	TypeRuntimeStatus                  = "runtime_status"
	TypeLoadModel                      = "load_model"
	TypePrefetchModel                  = "prefetch_model"
	TypeDesiredModels                  = "desired_models"

	// TypeCapacityProbe asks a provider whether it could admit a request of a
	// given bucketed shape right now. Carries shape metadata only — never
	// prompt content or identity. See CapacityProbeMessage.
	TypeCapacityProbe = "capacity_probe"
	TypeTrustStatus   = "trust_status"
)

// ProviderMessage is an envelope that can hold any provider→coordinator message.
// Use UnmarshalJSON to decode the concrete type based on the "type" field.
type ProviderMessage struct {
	Type    string
	Payload any // one of: *RegisterMessage, *HeartbeatMessage, etc.
}

// DecodeProviderMessage decodes one provider→coordinator frame into pm. It is
// the provider read loop's entry point and accepts exactly the inputs
// json.Unmarshal(data, pm) accepts, producing the same values — minus the
// whole-document validation pass encoding/json runs before invoking
// UnmarshalJSON. That pass is redundant here: every branch of UnmarshalJSON
// either validates the bytes it consumes itself (the chunk fast path) or hands
// the complete frame to encoding/json, which validates it.
// FuzzChunkFrameDecode holds the equivalence against json.Unmarshal.
func DecodeProviderMessage(data []byte, pm *ProviderMessage) error {
	return pm.UnmarshalJSON(data)
}

// UnmarshalJSON reads the "type" field first, then unmarshals the full object
// into the appropriate concrete struct.
//
// Fast path: scanTopLevelString reads "type" with a cheap byte walk so each
// frame is json.Unmarshal'ed exactly once. Previously every frame — including
// one per streamed token chunk — was parsed twice (envelope pass just to read
// "type", then the concrete struct). If the scanner is unsure (escapes,
// non-string value, malformed input, missing key) it falls back to the
// envelope decode, preserving the original error behavior.
func (pm *ProviderMessage) UnmarshalJSON(data []byte) error {
	// Fast path for the per-token chunk frame: a hand-written single-pass
	// decoder (chunk_scan.go) that never calls encoding/json. It bails on any
	// shape it is not certain about, in which case the frame takes the
	// generic path below exactly as before.
	if msg, ok := scanChunkFrame(data); ok {
		pm.Type = TypeInferenceResponseChunk
		pm.Payload = msg
		return nil
	}

	msgType, ok := scanTopLevelString(data, "type")
	if !ok {
		var envelope struct {
			Type string `json:"type"`
		}
		if err := json.Unmarshal(data, &envelope); err != nil {
			return fmt.Errorf("protocol: failed to read message type: %w", err)
		}
		msgType = envelope.Type
	}
	pm.Type = msgType

	switch msgType {
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

	case TypePrefixCacheLookup:
		var msg PrefixCacheLookupMessage
		if err := json.Unmarshal(data, &msg); err != nil {
			return fmt.Errorf("protocol: failed to unmarshal prefix_cache_lookup: %w", err)
		}
		pm.Payload = &msg

	case TypePrefixCacheReady:
		var msg PrefixCacheReadyMessage
		if err := json.Unmarshal(data, &msg); err != nil {
			return fmt.Errorf("protocol: failed to unmarshal prefix_cache_ready: %w", err)
		}
		pm.Payload = &msg

	case TypePrefixCacheLookupV2:
		var msg PrefixCacheLookupV2Message
		if err := json.Unmarshal(data, &msg); err != nil {
			return fmt.Errorf("protocol: failed to unmarshal prefix_cache_lookup_v2: %w", err)
		}
		pm.Payload = &msg

	case TypePrefixCacheReadyV2:
		var msg PrefixCacheReadyV2Message
		if err := json.Unmarshal(data, &msg); err != nil {
			return fmt.Errorf("protocol: failed to unmarshal prefix_cache_ready_v2: %w", err)
		}
		pm.Payload = &msg

	case TypeCapacityQuote:
		var msg CapacityQuoteMessage
		if err := json.Unmarshal(data, &msg); err != nil {
			return fmt.Errorf("protocol: failed to unmarshal capacity_quote: %w", err)
		}
		pm.Payload = &msg

	default:
		return fmt.Errorf("protocol: unknown message type %q", msgType)
	}

	return nil
}
