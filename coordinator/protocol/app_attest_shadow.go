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
	AvailabilityReason string               `json:"availability_reason,omitempty"`
	AppleErrorSource   string               `json:"apple_error_source,omitempty"`
	Proof              string               `json:"proof,omitempty"`
	EncryptedChallenge *EncryptedPayload    `json:"encrypted_challenge,omitempty"`
	// Optional provider runtime diagnostics on ready replies. They are never
	// part of the signed transcript; see SanitizeRuntimeDiagnostics.
	LaunchSession           string `json:"launch_session,omitempty"`
	BootTime                int64  `json:"boot_time,omitempty"`
	OperationStalledSeconds int    `json:"operation_stalled_seconds,omitempty"`
	// Optional deep diagnostics (app_attest_deep_diagnostic.go): lifecycle,
	// posture, preflight, key and push history on ready replies; the native error
	// chain on failed attestation/assertion replies. Never signed or trusted.
	ProcessStartedAt  int64                  `json:"process_started_at,omitempty"`
	PreviousExit      string                 `json:"previous_exit,omitempty"`
	StartReason       string                 `json:"start_reason,omitempty"`
	ConsoleUserActive *bool                  `json:"console_user_active,omitempty"`
	SIPEnabled        *bool                  `json:"sip_enabled,omitempty"`
	AuthenticatedRoot *bool                  `json:"authenticated_root,omitempty"`
	Preflight         *AppAttestPreflight    `json:"preflight,omitempty"`
	KeyHistory        *AppAttestKeyHistory   `json:"key_history,omitempty"`
	PushHistory       *AppAttestPushHistory  `json:"push_history,omitempty"`
	NativeErrorChain  []AppAttestNativeError `json:"native_error_chain,omitempty"`
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
