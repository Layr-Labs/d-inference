// Package wire implements conservative JSON frame scanners for the provider
// protocol. A false scanner result requires the caller to use encoding/json.
package wire

// TypeInferenceResponseChunk identifies the per-token provider frame.
const TypeInferenceResponseChunk = "inference_response_chunk"

// InferenceResponseChunkMessage carries a single SSE chunk from the provider.
// When E2E encryption is active, Data is empty and EncryptedData contains
// the encrypted chunk.
type InferenceResponseChunkMessage struct {
	Type          string            `json:"type"`
	RequestID     string            `json:"request_id"`
	Data          string            `json:"data,omitempty"`
	EncryptedData *EncryptedPayload `json:"encrypted_data,omitempty"`
}

// EncryptedPayload carries a NaCl Box encrypted message.
type EncryptedPayload struct {
	EphemeralPublicKey string `json:"ephemeral_public_key"` // sender's ephemeral X25519 public key (base64)
	Ciphertext         string `json:"ciphertext"`           // nonce || encrypted data (base64)
}
