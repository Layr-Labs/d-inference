package verification

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// VerifyRegistration verifies a provider's Secure Enclave attestation
// if one was included in the registration message. If the attestation is valid,
// the provider is marked as attested. If missing or invalid, the provider is
// accepted in Open Mode only when no binary hash policy is configured.
func (s *Verifier) VerifyRegistration(ctx context.Context, providerID string, provider *registry.Provider, regMsg *protocol.RegisterMessage) error {
	policyConfigured, knownBinaryHashes := s.deps.BinaryHashPolicy()
	if len(regMsg.Attestation) == 0 {
		if policyConfigured {
			s.deps.Logger().Warn("provider registered without attestation while binary hash policy is configured",
				"provider_id", providerID,
			)
			provider.SetAttestationResult(&attestation.VerificationResult{
				Valid: false,
				Error: "attestation missing",
			})
			s.deps.Registry().MarkUntrusted(providerID)
			return nil
		}
		s.deps.Logger().Info("provider registered without attestation (Open Mode)",
			"provider_id", providerID,
		)
		return nil
	}

	result, err := attestation.VerifyJSON(regMsg.Attestation)
	if err != nil {
		s.deps.Logger().Warn("failed to parse provider attestation",
			"provider_id", providerID,
			"error", err,
		)
		if policyConfigured {
			provider.SetAttestationResult(&attestation.VerificationResult{
				Valid: false,
				Error: "attestation invalid",
			})
			s.deps.Registry().MarkUntrusted(providerID)
		}
		return nil
	}

	provider.SetAttestationResult(&result)

	if !result.Valid {
		s.deps.Logger().Warn("provider attestation invalid",
			"provider_id", providerID,
			"error", result.Error,
		)
		if policyConfigured {
			s.deps.Registry().MarkUntrusted(providerID)
		}
		return nil
	}

	enforceReconnectFreshness := regMsg.Version != "" &&
		!s.deps.VersionLess(regMsg.Version, ReconnectFreshnessVersion)
	if enforceReconnectFreshness &&
		!attestation.CheckTimestamp(result, RegistrationMaxAge) {
		result.Valid = false
		result.Error = "attestation timestamp outside freshness window"
		provider.SetAttestationResult(&result)
		s.deps.Registry().MarkUntrusted(providerID)
		s.deps.Logger().Warn("provider registration attestation replay rejected",
			"provider_id", providerID)
		return nil
	}

	if !enforceReconnectFreshness {
		// Pre-0.8.15 providers reuse their signed registration blob across
		// reconnects. Preserve that legacy identity proof, but discard the
		// protected-runtime fields before storing it so no later trust or
		// challenge transition can promote apple_m5/mlx_nax from a replayable
		// claim. Their periodic nonce challenges remain the liveness proof.
		result.ChipFamily = ""
		result.RuntimeCapabilities = nil
		result.MetallibHash = ""
		provider.SetAttestationResult(&result)
	}

	// Bind the WebSocket X25519 key used for E2E text encryption to the
	// attested Secure Enclave identity. If a provider wants to serve private
	// text, the attestation must carry the same encryption public key.
	if regMsg.PublicKey != "" {
		if result.EncryptionPublicKey == "" {
			s.deps.Logger().Warn("attestation missing encryption key for registered public key",
				"provider_id", providerID,
			)
			result.Valid = false
			result.Error = "attestation missing encryption public key"
			provider.SetAttestationResult(&result)
			if policyConfigured {
				s.deps.Registry().MarkUntrusted(providerID)
			}
			return nil
		}
		if result.EncryptionPublicKey != regMsg.PublicKey {
			s.deps.Logger().Warn("attestation encryption key does not match register public key",
				"provider_id", providerID,
				"attestation_key", result.EncryptionPublicKey,
				"register_key", regMsg.PublicKey,
			)
			result.Valid = false
			result.Error = "encryption key mismatch"
			provider.SetAttestationResult(&result)
			if policyConfigured {
				s.deps.Registry().MarkUntrusted(providerID)
			}
			return nil
		}
	}

	// Verify binary hash against known-good hashes. Once a binary hash policy is
	// configured, omission is a policy violation, not an Open Mode downgrade.
	//
	// v0.6.0: binaryHash is self-reported and demoted to drift telemetry (APNs
	// code-identity attestation is the real signal); this gate deroutes only when
	// enforcement is explicitly enabled (rollback). The attestation-validity and
	// key-binding checks above remain gated on policyConfigured and are unchanged.
	if s.deps.EnforceBinaryHash() && policyConfigured {
		if result.BinaryHash == "" {
			s.deps.Logger().Warn("provider binary hash missing while known-good policy is configured",
				"provider_id", providerID,
			)
			result.Valid = false
			result.Error = "binary hash missing"
			provider.SetAttestationResult(&result)
			s.deps.Registry().MarkUntrusted(providerID)
			return nil
		}
		binaryHash, err := s.deps.NormalizeHash(result.BinaryHash, "binary_hash")
		if err != nil || !knownBinaryHashes[binaryHash] {
			s.deps.Logger().Warn("provider binary hash not in known-good list",
				"provider_id", providerID,
				"binary_hash", result.BinaryHash,
			)
			result.Valid = false
			result.Error = "binary hash not recognized"
			provider.SetAttestationResult(&result)
			s.deps.Registry().MarkUntrusted(providerID)
			return nil
		}
		s.deps.Logger().Info("provider binary hash verified",
			"provider_id", providerID,
			"binary_hash", registry.TruncHash(result.BinaryHash),
		)
	}

	provider.SetAttested(true, registry.TrustSelfSigned)
	s.deps.SendStatus(provider, registry.TrustSelfSigned, "online", "SE attestation verified, awaiting MDM verification")

	// Preserve registration freshness after the signed identity and key-binding
	// checks. This timestamp does not grant hardware trust or replace the live
	// challenge, MDM posture and routing gates.
	provider.SetLastChallengeVerified(time.Now())

	s.deps.Logger().Info("provider attestation verified (self-signed)",
		"provider_id", providerID,
		"hardware_model", result.HardwareModel,
		"chip_name", result.ChipName,
		"serial_number", result.SerialNumber,
		"secure_enclave", result.SecureEnclaveAvailable,
		"sip_enabled", result.SIPEnabled,
		"secure_boot", result.SecureBootEnabled,
		"authenticated_root", result.AuthenticatedRootEnabled,
		"system_volume_hash", result.SystemVolumeHash,
		"binary_hash", result.BinaryHash,
		"trust_level", registry.TrustSelfSigned,
	)

	// Resolve only this freshly verified identity, rather than loading all historical
	// sessions before startup. Exclude every live session and keep incomplete
	// registrations' identities unpublished across asynchronous persistence.
	if err := s.Restore(ctx, provider, result.SerialNumber, result.PublicKey); err != nil {
		return err
	}

	// Independently recover the newest non-empty durable MDA chain. A newer
	// empty record must not shadow a chain earned by an earlier session. The
	// hardware-grant path still re-verifies the certificate and SE-key binding.
	s.StageMDA(provider, result.SerialNumber)

	// Deduplicate: if another provider connection exists from the same physical
	// device (same serial number), disconnect it. This prevents multiple
	// provider processes on the same machine from registering independently
	// and competing for the same machine resources.
	if result.SerialNumber != "" && !s.deps.AllowDuplicateSerials() {
		s.deps.Registry().DisconnectDuplicatesBySerial(providerID, result.SerialNumber)
	}

	// Persist provider state after attestation verification.
	// This captures the attestation result, serial number, and trust level.
	s.deps.Registry().PersistProvider(provider)

	// MDM verification is not spawned here. Registration binds stable device work
	// to the Server-owned bounded scheduler after attestation has established the
	// Secure Enclave identity and serial.
	if s.deps.MDM() != nil && result.SerialNumber == "" {
		s.deps.Logger().Warn("provider attestation has no serial number — cannot verify via MDM",
			"provider_id", providerID,
		)
	}
	return nil
}
