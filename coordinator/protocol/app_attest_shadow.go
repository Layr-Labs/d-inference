package protocol

import (
	"crypto/sha256"
	"encoding/binary"
	"errors"
)

const TypeAppAttestShadow = "app_attest_shadow"

// ErrAppAttestShadowFrameTooLarge lets the connection account for a refused
// shadow frame without decoding or retaining its oversized proof payload.
var ErrAppAttestShadowFrameTooLarge = errors.New("protocol: oversized app attest shadow")

// AppAttestShadow is deliberately separate from the authoritative attestation messages.
// action: prepare -> ready -> attest -> attestation -> assert -> assertion.
// Unsupported/API errors use result != "ok". No message grants or removes trust.
type AppAttestShadowMessage struct {
	Type    string                 `json:"type"`
	Payload AppAttestShadowPayload `json:"payload"`
}

type AppAttestShadowPayload struct {
	ProtocolVersion    int                  `json:"protocol_version,omitempty"`
	AccountScope       string               `json:"account_scope,omitempty"`
	EnrollmentSession  string               `json:"enrollment_session,omitempty"`
	Status             *AppAttestStatus     `json:"status,omitempty"`
	Action             string               `json:"action"`
	Session            string               `json:"session"`
	Environment        string               `json:"environment,omitempty"`
	KeyID              string               `json:"key_id,omitempty"`
	Challenge          string               `json:"challenge,omitempty"`
	Result             string               `json:"result,omitempty"`
	AppleError         *AppAttestAppleError `json:"apple_error,omitempty"`
	Proof              string               `json:"proof,omitempty"`
	EncryptedChallenge *EncryptedPayload    `json:"encrypted_challenge,omitempty"`
}

// AppAttestShadowHash is length-prefixed UTF-8 to avoid JSON canonicalization ambiguity.
// The public key is supplied from the app's own NodeKeyPair, never from the challenge.
func AppAttestShadowHash(action, session, environment, keyID, challenge, publicKey string) [32]byte {
	h := sha256.New()
	for _, value := range []string{"darkbloom.app-attest.shadow.v1", action, session, environment, keyID, challenge, publicKey} {
		var length [4]byte
		binary.BigEndian.PutUint32(length[:], uint32(len(value)))
		h.Write(length[:])
		h.Write([]byte(value))
	}
	var result [32]byte
	copy(result[:], h.Sum(nil))
	return result
}
