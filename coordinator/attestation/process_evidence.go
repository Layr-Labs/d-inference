package attestation

import (
	"bytes"
	"encoding/json"
	"fmt"
)

const (
	ProcessEvidenceV1     = "process_evidence_v1"
	ProcessEvidenceDomain = "darkbloom.process_evidence"
)

// ProcessEvidenceCanonicalInput is the complete, immutable v1 signing contract.
// Do not add fields to this type's encoding. A future field requires a new
// transcript version so deployed signatures cannot change meaning.
type ProcessEvidenceCanonicalInput struct {
	CoordinatorNonce     string
	CoordinatorTimestamp string
	CoordinatorSessionID string
	ChallengeGeneration  string
	EvidenceExpiresAt    string
	SEPublicKey          string
	SerialNumber         string
	ProcessPublicKey     string
	BinaryHash           string
	ProviderVersion      string
	ProviderPlatform     string
	ProviderBackend      string
	RuntimeHash          string
	MetallibHash         string
	SIPEnabled           *bool
	SecureBootEnabled    *bool
}

// BuildProcessEvidenceCanonicalV1 serializes the fixed process_evidence_v1
// contract. String fields are always present, including empty strings. Posture
// booleans deliberately distinguish nil (omitted) from false (encoded false).
// Go's map encoder sorts keys; HTML escaping and the trailing newline are
// disabled to mirror Swift JSONSerialization(.sortedKeys).
func BuildProcessEvidenceCanonicalV1(in ProcessEvidenceCanonicalInput) ([]byte, error) {
	m := map[string]any{
		"binary_hash":            in.BinaryHash,
		"challenge_generation":   in.ChallengeGeneration,
		"coordinator_nonce":      in.CoordinatorNonce,
		"coordinator_session_id": in.CoordinatorSessionID,
		"coordinator_timestamp":  in.CoordinatorTimestamp,
		"domain":                 ProcessEvidenceDomain,
		"evidence_expires_at":    in.EvidenceExpiresAt,
		"metallib_hash":          in.MetallibHash,
		"process_public_key":     in.ProcessPublicKey,
		"provider_backend":       in.ProviderBackend,
		"provider_platform":      in.ProviderPlatform,
		"provider_version":       in.ProviderVersion,
		"runtime_hash":           in.RuntimeHash,
		"se_public_key":          in.SEPublicKey,
		"serial_number":          in.SerialNumber,
		"version":                ProcessEvidenceV1,
	}
	if in.SIPEnabled != nil {
		m["sip_enabled"] = *in.SIPEnabled
	}
	if in.SecureBootEnabled != nil {
		m["secure_boot_enabled"] = *in.SecureBootEnabled
	}

	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(m); err != nil {
		return nil, fmt.Errorf("encode process evidence v1: %w", err)
	}
	return bytes.TrimSuffix(buf.Bytes(), []byte("\n")), nil
}

func VerifyProcessEvidenceSignatureV1(
	sePublicKeyB64, signatureB64 string,
	in ProcessEvidenceCanonicalInput,
) error {
	if signatureB64 == "" {
		return ErrStatusSignatureMissing
	}
	canonical, err := BuildProcessEvidenceCanonicalV1(in)
	if err != nil {
		return err
	}
	return VerifyChallengeSignature(sePublicKeyB64, signatureB64, string(canonical))
}
