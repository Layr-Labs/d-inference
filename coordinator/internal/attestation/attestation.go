// Package attestation verifies signed attestation blobs from Darkbloom
// provider nodes.
//
// Each provider generates an attestation blob containing hardware identity
// (chip name, machine model), software security state (SIP, Secure Boot),
// and the provider's public keys. The blob is signed using a P-256 ECDSA
// key held in the Apple Secure Enclave — the private key never leaves the
// hardware.
//
// Cross-language JSON compatibility:
//
//	The attestation blob is signed over its JSON representation. Swift's
//	JSONEncoder with .sortedKeys produces alphabetically-sorted keys, while
//	Go's encoding/json marshals struct fields in declaration order. To ensure
//	both produce identical JSON for signature verification, the Go struct
//	fields are declared in alphabetical order by JSON key name, and a
//	marshalSortedJSON helper is provided as a fallback.
//
// Verification checks:
//  1. P-256 ECDSA signature validity against the embedded public key
//  2. Secure Enclave availability (required)
//  3. SIP enabled (required)
//  4. Secure Boot enabled (required)
//  5. Optional: encryption public key matches registration key
package attestation

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/sha256"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"time"
)

// AttestationBlob mirrors the Swift AttestationBlob struct.
// JSON field names must match exactly for signature verification.
// AttestationBlob fields are in alphabetical order by JSON key name.
// This is critical: Go's json.Marshal uses struct declaration order,
// and Swift's JSONEncoder with .sortedKeys uses alphabetical order.
// Keeping them aligned ensures both produce identical JSON.
type AttestationBlob struct {
	AuthenticatedRootEnabled bool   `json:"authenticatedRootEnabled"`
	BinaryHash               string `json:"binaryHash,omitempty"`
	ChipName                 string `json:"chipName"`
	EncryptionPublicKey      string `json:"encryptionPublicKey,omitempty"`
	HardwareModel            string `json:"hardwareModel"`
	HypervisorActive         bool   `json:"hypervisorActive"`
	OSVersion                string `json:"osVersion"`
	PublicKey                string `json:"publicKey"`
	RDMADisabled             bool   `json:"rdmaDisabled"`
	SecureBootEnabled        bool   `json:"secureBootEnabled"`
	SecureEnclaveAvailable   bool   `json:"secureEnclaveAvailable"`
	SerialNumber             string `json:"serialNumber,omitempty"`
	SIPEnabled               bool   `json:"sipEnabled"`
	SystemVolumeHash         string `json:"systemVolumeHash,omitempty"`
	Timestamp                string `json:"timestamp"`
}

// SignedAttestation is a signed attestation blob with a base64-encoded
// DER ECDSA signature. The AttestationRaw field preserves the exact JSON
// bytes from the provider (needed for signature verification, since Swift
// and Go encode JSON slightly differently — e.g., Swift escapes forward
// slashes in base64 strings).
type SignedAttestation struct {
	Attestation    AttestationBlob `json:"attestation"`
	AttestationRaw json.RawMessage `json:"-"` // original bytes for verification
	Signature      string          `json:"signature"`
}

// UnmarshalJSON preserves the raw attestation bytes for signature verification.
func (s *SignedAttestation) UnmarshalJSON(data []byte) error {
	// Parse into a raw structure to capture the attestation bytes exactly
	var raw struct {
		Attestation json.RawMessage `json:"attestation"`
		Signature   string          `json:"signature"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}

	s.AttestationRaw = raw.Attestation
	s.Signature = raw.Signature

	// Also parse the attestation into the typed struct for field access
	return json.Unmarshal(raw.Attestation, &s.Attestation)
}

// VerificationResult contains the outcome of attestation verification.
type VerificationResult struct {
	Valid                    bool
	PublicKey                string
	EncryptionPublicKey      string
	BinaryHash               string
	HardwareModel            string
	ChipName                 string
	SerialNumber             string
	SecureEnclaveAvailable   bool
	SIPEnabled               bool
	SecureBootEnabled        bool
	HypervisorActive         bool
	RDMADisabled             bool
	AuthenticatedRootEnabled bool
	SystemVolumeHash         string
	Timestamp                time.Time
	Error                    string
}

// ecdsaSig holds the two integers in a DER-encoded ECDSA signature.
type ecdsaSig struct {
	R, S *big.Int
}

// Verify checks a signed attestation's P-256 ECDSA signature against
// the public key embedded in the attestation blob.
//
// The verification re-encodes the attestation blob as JSON with sorted
// keys (matching Swift's JSONEncoder with .sortedKeys), hashes with
// SHA-256, then verifies the ECDSA signature.
//
// It also checks minimum security requirements: Secure Enclave must be
// available, SIP must be enabled, and Secure Boot must be enabled.
func Verify(signed SignedAttestation) VerificationResult {
	result := VerificationResult{
		PublicKey:                signed.Attestation.PublicKey,
		EncryptionPublicKey:      signed.Attestation.EncryptionPublicKey,
		BinaryHash:               signed.Attestation.BinaryHash,
		HardwareModel:            signed.Attestation.HardwareModel,
		ChipName:                 signed.Attestation.ChipName,
		SerialNumber:             signed.Attestation.SerialNumber,
		SecureEnclaveAvailable:   signed.Attestation.SecureEnclaveAvailable,
		SIPEnabled:               signed.Attestation.SIPEnabled,
		SecureBootEnabled:        signed.Attestation.SecureBootEnabled,
		HypervisorActive:         signed.Attestation.HypervisorActive,
		RDMADisabled:             signed.Attestation.RDMADisabled,
		AuthenticatedRootEnabled: signed.Attestation.AuthenticatedRootEnabled,
		SystemVolumeHash:         signed.Attestation.SystemVolumeHash,
	}

	// Parse timestamp
	ts, err := time.Parse(time.RFC3339Nano, signed.Attestation.Timestamp)
	if err != nil {
		// Try without fractional seconds
		ts, err = time.Parse(time.RFC3339, signed.Attestation.Timestamp)
		if err != nil {
			result.Error = fmt.Sprintf("invalid timestamp: %v", err)
			return result
		}
	}
	result.Timestamp = ts

	// Decode public key from base64 (raw P-256 uncompressed point, 65 bytes)
	pubKeyBytes, err := base64.StdEncoding.DecodeString(signed.Attestation.PublicKey)
	if err != nil {
		result.Error = fmt.Sprintf("invalid public key base64: %v", err)
		return result
	}

	pubKey, err := ParseP256PublicKey(pubKeyBytes)
	if err != nil {
		result.Error = fmt.Sprintf("invalid public key: %v", err)
		return result
	}

	// Decode signature from base64 (DER-encoded ECDSA)
	sigBytes, err := base64.StdEncoding.DecodeString(signed.Signature)
	if err != nil {
		result.Error = fmt.Sprintf("invalid signature base64: %v", err)
		return result
	}

	// Use the original attestation JSON bytes for verification.
	// Swift and Go encode JSON slightly differently (e.g., Swift escapes
	// forward slashes as \/ in base64 strings). Using the original bytes
	// ensures the hash matches what the Secure Enclave signed.
	var blobJSON []byte
	if len(signed.AttestationRaw) > 0 {
		blobJSON = signed.AttestationRaw
	} else {
		// Fallback: re-encode (works for Go-generated test attestations)
		var err error
		blobJSON, err = marshalSortedJSON(signed.Attestation)
		if err != nil {
			result.Error = fmt.Sprintf("failed to re-encode attestation: %v", err)
			return result
		}
	}

	// Hash and verify
	hash := sha256.Sum256(blobJSON)

	var sig ecdsaSig
	if _, err := asn1.Unmarshal(sigBytes, &sig); err != nil {
		result.Error = fmt.Sprintf("invalid DER signature: %v", err)
		return result
	}

	if !ecdsa.Verify(pubKey, hash[:], sig.R, sig.S) {
		result.Error = "signature verification failed"
		return result
	}

	result.Valid = true

	// Check minimum security requirements
	if !signed.Attestation.SecureEnclaveAvailable {
		result.Valid = false
		result.Error = "Secure Enclave not available"
	}
	if !signed.Attestation.SIPEnabled {
		result.Valid = false
		result.Error = "SIP not enabled"
	}
	if !signed.Attestation.SecureBootEnabled {
		result.Valid = false
		result.Error = "Secure Boot not enabled"
	}
	// RDMA status in the attestation blob is informational — old enclave binaries
	// don't include this field (defaults to false). The real RDMA check happens in
	// the challenge-response flow where the provider reports fresh rdma_ctl status.
	// TEMPORARY: once all providers run v0.2.0+ enclave, enforce this.
	// ARV is informational — not all environments report it reliably
	// (e.g. multi-boot Macs, older macOS). Logged but not enforced.
	result.AuthenticatedRootEnabled = signed.Attestation.AuthenticatedRootEnabled

	return result
}

// VerifyJSON verifies a signed attestation from raw JSON bytes.
func VerifyJSON(jsonData []byte) (VerificationResult, error) {
	var signed SignedAttestation
	if err := json.Unmarshal(jsonData, &signed); err != nil {
		return VerificationResult{}, fmt.Errorf("invalid attestation JSON: %w", err)
	}
	return Verify(signed), nil
}

// CheckTimestamp verifies that the attestation timestamp is within the
// given maximum age. This prevents replay of old attestations.
func CheckTimestamp(result VerificationResult, maxAge time.Duration) bool {
	if result.Timestamp.IsZero() {
		return false
	}
	return time.Since(result.Timestamp) <= maxAge
}

// ParseP256PublicKey parses a raw P-256 public key point.
// Accepts uncompressed format (65 bytes: 0x04 || X || Y) or raw X||Y (64 bytes).
func ParseP256PublicKey(raw []byte) (*ecdsa.PublicKey, error) {
	curve := elliptic.P256()

	if len(raw) == 65 && raw[0] == 0x04 {
		// Uncompressed point
		x := new(big.Int).SetBytes(raw[1:33])
		y := new(big.Int).SetBytes(raw[33:65])

		if !curve.IsOnCurve(x, y) {
			return nil, errors.New("point is not on the P-256 curve")
		}

		return &ecdsa.PublicKey{Curve: curve, X: x, Y: y}, nil
	}

	// Also handle the case where CryptoKit returns raw X||Y (64 bytes)
	// without the 0x04 prefix
	if len(raw) == 64 {
		x := new(big.Int).SetBytes(raw[0:32])
		y := new(big.Int).SetBytes(raw[32:64])

		if !curve.IsOnCurve(x, y) {
			return nil, errors.New("point is not on the P-256 curve")
		}

		return &ecdsa.PublicKey{Curve: curve, X: x, Y: y}, nil
	}

	return nil, fmt.Errorf(
		"unsupported public key format: expected 64 or 65 bytes, got %d",
		len(raw),
	)
}

// marshalSortedJSON re-encodes the attestation blob as JSON with keys
// in alphabetical order, matching Swift's JSONEncoder with .sortedKeys.
//
// Go's encoding/json marshals struct fields in declaration order, which
// may not match Swift's alphabetical order. We use a map to ensure
// correct key ordering.
func marshalSortedJSON(blob AttestationBlob) ([]byte, error) {
	// Build an ordered map matching Swift's .sortedKeys output.
	// Swift sorts keys alphabetically (Unicode code point order).
	// encoding/json marshals map keys in sorted order as of Go 1.12+.
	m := map[string]interface{}{
		"authenticatedRootEnabled": blob.AuthenticatedRootEnabled,
		"chipName":                 blob.ChipName,
		"hardwareModel":            blob.HardwareModel,
		"hypervisorActive":         blob.HypervisorActive,
		"osVersion":                blob.OSVersion,
		"publicKey":                blob.PublicKey,
		"rdmaDisabled":             blob.RDMADisabled,
		"secureBootEnabled":        blob.SecureBootEnabled,
		"secureEnclaveAvailable":   blob.SecureEnclaveAvailable,
		"sipEnabled":               blob.SIPEnabled,
		"timestamp":                blob.Timestamp,
	}

	// Only include optional fields if set (Swift's JSONEncoder with
	// .sortedKeys omits nil optionals, so we must match that behavior).
	if blob.BinaryHash != "" {
		m["binaryHash"] = blob.BinaryHash
	}
	if blob.EncryptionPublicKey != "" {
		m["encryptionPublicKey"] = blob.EncryptionPublicKey
	}
	if blob.SerialNumber != "" {
		m["serialNumber"] = blob.SerialNumber
	}
	if blob.SystemVolumeHash != "" {
		m["systemVolumeHash"] = blob.SystemVolumeHash
	}

	return json.Marshal(m)
}

// VerifyChallengeSignature verifies a P-256 ECDSA signature over challenge
// data (nonce + timestamp) using the provider's Secure Enclave public key.
//
// Parameters:
//   - sePublicKeyB64: base64-encoded raw P-256 public key (64 or 65 bytes)
//   - signatureB64: base64-encoded DER-encoded ECDSA signature
//   - data: the signed data (nonce + timestamp concatenated)
//
// Returns nil on success, an error describing the failure otherwise.
func VerifyChallengeSignature(sePublicKeyB64, signatureB64, data string) error {
	// Decode public key
	pubKeyBytes, err := base64.StdEncoding.DecodeString(sePublicKeyB64)
	if err != nil {
		return fmt.Errorf("invalid SE public key base64: %w", err)
	}

	pubKey, err := ParseP256PublicKey(pubKeyBytes)
	if err != nil {
		return fmt.Errorf("invalid SE public key: %w", err)
	}

	// Decode signature
	sigBytes, err := base64.StdEncoding.DecodeString(signatureB64)
	if err != nil {
		return fmt.Errorf("invalid signature base64: %w", err)
	}

	// Hash the challenge data
	hash := sha256.Sum256([]byte(data))

	// Parse DER-encoded ECDSA signature
	var sig ecdsaSig
	if _, err := asn1.Unmarshal(sigBytes, &sig); err != nil {
		return fmt.Errorf("invalid DER signature: %w", err)
	}

	// Verify
	if !ecdsa.Verify(pubKey, hash[:], sig.R, sig.S) {
		return errors.New("ECDSA signature verification failed")
	}

	return nil
}
