package attestation

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/sha256"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
)

const (
	ProviderIdentityRegistrationDomain = "darkbloom.provider.registration.v1"
	ProviderIdentityChallengeDomain    = "darkbloom.provider.challenge.v1"
)

// ProviderIdentityPrivacyCapabilities mirrors the privacy fields signed by the
// provider-bound identity during registration. These are provider-local process
// invariants, so they are only useful when bound to the entitlement-gated key.
type ProviderIdentityPrivacyCapabilities struct {
	TextBackendInprocess    bool
	TextProxyDisabled       bool
	PythonRuntimeLocked     bool
	DangerousModulesBlocked bool
	SIPEnabled              bool
	AntiDebugEnabled        bool
	CoreDumpsDisabled       bool
	EnvScrubbed             bool
	HypervisorActive        bool
}

type ProviderIdentityRegistrationInput struct {
	ProviderIdentityPublicKey string
	PublicKey                 string
	BinaryHash                string
	Version                   string
	Backend                   string
	EncryptedResponseChunks   bool
	PythonHash                string
	RuntimeHash               string
	TemplateHashes            map[string]string
	PrivacyCapabilities       *ProviderIdentityPrivacyCapabilities
}

type ProviderIdentityChallengeInput struct {
	ProviderIdentityPublicKey string
	PublicKey                 string
	Nonce                     string
	Timestamp                 string
	HypervisorActive          *bool
	RDMADisabled              *bool
	SIPEnabled                *bool
	SecureBootEnabled         *bool
	BinaryHash                string
	ActiveModelHash           string
	PythonHash                string
	RuntimeHash               string
	TemplateHashes            map[string]string
	ModelHashes               map[string]string
}

func BuildProviderIdentityRegistrationCanonical(in ProviderIdentityRegistrationInput) ([]byte, error) {
	m := map[string]any{
		"backend":                      in.Backend,
		"domain":                       ProviderIdentityRegistrationDomain,
		"encrypted_response_chunks":    in.EncryptedResponseChunks,
		"provider_identity_public_key": in.ProviderIdentityPublicKey,
	}
	if in.PublicKey != "" {
		m["public_key"] = in.PublicKey
	}
	if in.BinaryHash != "" {
		m["binary_hash"] = in.BinaryHash
	}
	if in.Version != "" {
		m["version"] = in.Version
	}
	if in.PythonHash != "" {
		m["python_hash"] = in.PythonHash
	}
	if in.RuntimeHash != "" {
		m["runtime_hash"] = in.RuntimeHash
	}
	if len(in.TemplateHashes) > 0 {
		m["template_hashes"] = in.TemplateHashes
	}
	if in.PrivacyCapabilities != nil {
		m["privacy_capabilities"] = map[string]any{
			"anti_debug_enabled":        in.PrivacyCapabilities.AntiDebugEnabled,
			"core_dumps_disabled":       in.PrivacyCapabilities.CoreDumpsDisabled,
			"dangerous_modules_blocked": in.PrivacyCapabilities.DangerousModulesBlocked,
			"env_scrubbed":              in.PrivacyCapabilities.EnvScrubbed,
			"hypervisor_active":         in.PrivacyCapabilities.HypervisorActive,
			"python_runtime_locked":     in.PrivacyCapabilities.PythonRuntimeLocked,
			"sip_enabled":               in.PrivacyCapabilities.SIPEnabled,
			"text_backend_inprocess":    in.PrivacyCapabilities.TextBackendInprocess,
			"text_proxy_disabled":       in.PrivacyCapabilities.TextProxyDisabled,
		}
	}
	return marshalProviderIdentityCanonical(m)
}

func BuildProviderIdentityChallengeCanonical(in ProviderIdentityChallengeInput) ([]byte, error) {
	m := map[string]any{
		"domain":                       ProviderIdentityChallengeDomain,
		"nonce":                        in.Nonce,
		"provider_identity_public_key": in.ProviderIdentityPublicKey,
		"public_key":                   in.PublicKey,
		"timestamp":                    in.Timestamp,
	}
	if in.HypervisorActive != nil {
		m["hypervisor_active"] = *in.HypervisorActive
	}
	if in.RDMADisabled != nil {
		m["rdma_disabled"] = *in.RDMADisabled
	}
	if in.SIPEnabled != nil {
		m["sip_enabled"] = *in.SIPEnabled
	}
	if in.SecureBootEnabled != nil {
		m["secure_boot_enabled"] = *in.SecureBootEnabled
	}
	if in.BinaryHash != "" {
		m["binary_hash"] = in.BinaryHash
	}
	if in.ActiveModelHash != "" {
		m["active_model_hash"] = in.ActiveModelHash
	}
	if in.PythonHash != "" {
		m["python_hash"] = in.PythonHash
	}
	if in.RuntimeHash != "" {
		m["runtime_hash"] = in.RuntimeHash
	}
	if len(in.TemplateHashes) > 0 {
		m["template_hashes"] = in.TemplateHashes
	}
	if len(in.ModelHashes) > 0 {
		m["model_hashes"] = in.ModelHashes
	}
	return marshalProviderIdentityCanonical(m)
}

func marshalProviderIdentityCanonical(v any) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(buf.Bytes(), []byte("\n")), nil
}

func VerifyProviderIdentitySignature(providerIdentityPublicKeyB64, signatureB64 string, data []byte) error {
	if providerIdentityPublicKeyB64 == "" {
		return errors.New("provider identity public key missing")
	}
	if signatureB64 == "" {
		return errors.New("provider identity signature missing")
	}

	pubKeyBytes, err := base64.StdEncoding.DecodeString(providerIdentityPublicKeyB64)
	if err != nil {
		return fmt.Errorf("invalid provider identity public key base64: %w", err)
	}
	pubKey, err := ParseP256PublicKey(pubKeyBytes)
	if err != nil {
		return fmt.Errorf("invalid provider identity public key: %w", err)
	}

	sigBytes, err := base64.StdEncoding.DecodeString(signatureB64)
	if err != nil {
		return fmt.Errorf("invalid provider identity signature base64: %w", err)
	}

	if !verifyECDSASHA256(pubKey, sigBytes, data) {
		return errors.New("provider identity signature verification failed")
	}
	return nil
}

func verifyECDSASHA256(pubKey *ecdsa.PublicKey, sigBytes, data []byte) bool {
	var sig ecdsaSig
	if _, err := asn1.Unmarshal(sigBytes, &sig); err != nil {
		return false
	}
	hash := sha256.Sum256(data)
	return ecdsa.Verify(pubKey, hash[:], sig.R, sig.S)
}
