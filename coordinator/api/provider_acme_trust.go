package api

import (
	"encoding/base64"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func (s *Server) applyACMETrust(providerID string, provider *registry.Provider, acmeResult *ACMEVerificationResult) {
	if acmeResult == nil || !acmeResult.Valid {
		return
	}

	provider.Mu().Lock()
	provider.ACMEVerified = true
	provider.Mu().Unlock()

	if !providerHasBoundEncryptionAttestation(provider) {
		s.logger.Warn("ACME client cert verified but X25519 key was not bound by attestation",
			"provider_id", providerID,
			"acme_serial", acmeResult.SerialNumber,
			"acme_issuer", acmeResult.Issuer,
			"acme_key_alg", acmeResult.PublicKeyAlg,
		)
		return
	}
	if !providerAttestationMatchesACMEKey(provider, acmeResult) {
		s.logger.Warn("ACME client cert key does not match the attested Secure Enclave key",
			"provider_id", providerID,
			"acme_serial", acmeResult.SerialNumber,
			"acme_issuer", acmeResult.Issuer,
			"acme_key_alg", acmeResult.PublicKeyAlg,
		)
		return
	}

	provider.SetAttested(true, registry.TrustHardware)
	s.sendTrustStatus(provider, registry.TrustHardware, "online", "ACME device attestation verified")
	s.logger.Info("ACME client cert verified — hardware trust via Apple SE attestation",
		"provider_id", providerID,
		"acme_serial", acmeResult.SerialNumber,
		"acme_issuer", acmeResult.Issuer,
		"acme_key_alg", acmeResult.PublicKeyAlg,
	)
}

func providerHasBoundEncryptionAttestation(provider *registry.Provider) bool {
	provider.Mu().Lock()
	defer provider.Mu().Unlock()

	if provider.PublicKey == "" || provider.AttestationResult == nil || !provider.AttestationResult.Valid {
		return false
	}

	return provider.AttestationResult.EncryptionPublicKey != "" &&
		provider.AttestationResult.EncryptionPublicKey == provider.PublicKey
}

func providerAttestationMatchesACMEKey(provider *registry.Provider, acmeResult *ACMEVerificationResult) bool {
	if acmeResult == nil || acmeResult.PublicKey == "" {
		return false
	}

	provider.Mu().Lock()
	if provider.AttestationResult == nil || !provider.AttestationResult.Valid {
		provider.Mu().Unlock()
		return false
	}
	attestedKeyB64 := provider.AttestationResult.PublicKey
	provider.Mu().Unlock()

	if attestedKeyB64 == "" {
		return false
	}

	attestedRaw, err := base64.StdEncoding.DecodeString(attestedKeyB64)
	if err != nil {
		return false
	}
	acmeRaw, err := base64.StdEncoding.DecodeString(acmeResult.PublicKey)
	if err != nil {
		return false
	}

	attestedKey, err := attestation.ParseP256PublicKey(attestedRaw)
	if err != nil {
		return false
	}
	acmeKey, err := attestation.ParseP256PublicKey(acmeRaw)
	if err != nil {
		return false
	}

	return attestedKey.X.Cmp(acmeKey.X) == 0 && attestedKey.Y.Cmp(acmeKey.Y) == 0
}
