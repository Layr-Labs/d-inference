package protocol

import (
	"encoding/json"
	"fmt"
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

	var payload any
	switch msgType {
	case TypeRegister:
		payload = &RegisterMessage{}
	case TypeAppAttestShadow:
		if len(data) > 48*1024 {
			return ErrAppAttestShadowFrameTooLarge
		}
		payload = &AppAttestShadowMessage{}
	case TypeHeartbeat:
		payload = &HeartbeatMessage{}
	case TypeInferenceAccepted:
		payload = &InferenceAcceptedMessage{}
	case TypeInferenceResponseChunk:
		payload = &InferenceResponseChunkMessage{}
	case TypeInferenceComplete:
		payload = &InferenceCompleteMessage{}
	case TypeInferenceError:
		payload = &InferenceErrorMessage{}
	case TypeAttestationResponse:
		payload = &AttestationResponseMessage{}
	case TypeCodeAttestationResponse:
		payload = &CodeAttestationResponseMessage{}
	case TypeLoadModelStatus:
		payload = &LoadModelStatusMessage{}
	case TypePrefetchModelStatus:
		payload = &PrefetchModelStatusMessage{}
	case TypeModelsUpdate:
		payload = &ModelsUpdateMessage{}
	case TypePrefixCacheLookup:
		payload = &PrefixCacheLookupMessage{}
	case TypePrefixCacheReady:
		payload = &PrefixCacheReadyMessage{}
	case TypePrefixCacheLookupV2:
		payload = &PrefixCacheLookupV2Message{}
	case TypePrefixCacheReadyV2:
		payload = &PrefixCacheReadyV2Message{}
	case TypeCapacityQuote:
		payload = &CapacityQuoteMessage{}
	default:
		return fmt.Errorf("protocol: unknown message type %q", msgType)
	}

	if err := json.Unmarshal(data, payload); err != nil {
		if msgType == TypeAppAttestShadow {
			return fmt.Errorf("protocol: malformed app attest shadow")
		}
		return fmt.Errorf("protocol: failed to unmarshal %s: %w", msgType, err)
	}
	pm.Payload = payload

	return nil
}
