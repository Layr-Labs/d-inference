package trust

// Provider WebSocket management for the Darkbloom coordinator.
//
// This file handles the provider side of the coordinator: WebSocket connections,
// provider registration, attestation verification, challenge-response loops,
// and inference request/response relay.
//
// Provider lifecycle:
//   1. Provider connects via WebSocket to /ws/provider
//   2. Provider sends a Register message with hardware info, models, and attestation
//   3. Coordinator verifies attestation (Secure Enclave P-256 signature)
//   4. Coordinator starts periodic challenge-response loop to verify liveness
//   5. Coordinator routes inference requests to the provider via WebSocket
//   6. Provider streams response chunks back through the WebSocket
//   7. Coordinator relays chunks to the waiting consumer HTTP handler
//
// Attestation trust levels:
//   - none: No attestation provided (Open Mode, still accepted)
//   - self_signed: Attestation signed by provider's own Secure Enclave key
//   - hardware: MDA certificate chain verified against Apple Root CA (future)

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/releases"
	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// VerifyProviderAttestation verifies a provider's Secure Enclave attestation
// if one was included in the registration message. If the attestation is valid,
// the provider is marked as attested. If missing or invalid, the provider is
// accepted in Open Mode only when no binary hash policy is configured.
func (s *Owner) VerifyProviderAttestation(ctx context.Context, providerID string, provider *registry.Provider, regMsg *protocol.RegisterMessage, authenticatedAccount ...string) error {
	account := ""
	if len(authenticatedAccount) > 0 {
		account = authenticatedAccount[0]
	}
	identityCandidate := s.AppAttestIdentityCandidate(regMsg, account)
	policyConfigured, knownBinaryHashes := s.releases.BinaryHashPolicySnapshot()
	if len(regMsg.Attestation) == 0 {
		if policyConfigured {
			s.logger.Warn("provider registered without attestation while binary hash policy is configured",
				"provider_id", providerID,
			)
			provider.SetAttestationResult(&attestation.VerificationResult{
				Valid: false,
				Error: "attestation missing",
			})
			s.registry.MarkUntrusted(providerID)
			return nil
		}
		s.logger.Info("provider registered without attestation (Open Mode)",
			"provider_id", providerID,
		)
		return nil
	}

	result, err := attestation.VerifyJSON(regMsg.Attestation)
	if err != nil {
		s.logger.Warn("failed to parse provider attestation",
			"provider_id", providerID,
			"error", err,
		)
		if policyConfigured {
			provider.SetAttestationResult(&attestation.VerificationResult{
				Valid: false,
				Error: "attestation invalid",
			})
			s.registry.MarkUntrusted(providerID)
		}
		return nil
	}

	provider.SetAttestationResult(&result)

	if !result.Valid {
		s.logger.Warn("provider attestation invalid",
			"provider_id", providerID,
			"error", result.Error,
		)
		if policyConfigured {
			s.registry.MarkUntrusted(providerID)
		}
		return nil
	}

	// Providers rebuild and re-sign their registration attestation on every
	// reconnect, so a stale timestamp is a replay of an old signed claim.
	if !attestation.CheckTimestamp(result, RegistrationAttestationMaxAge) {
		result.Valid = false
		result.Error = "attestation timestamp outside freshness window"
		provider.SetAttestationResult(&result)
		s.registry.MarkUntrusted(providerID)
		s.logger.Warn("provider registration attestation replay rejected",
			"provider_id", providerID)
		return nil
	}

	// Bind the WebSocket X25519 key used for E2E text encryption to the
	// attested Secure Enclave identity. If a provider wants to serve private
	// text, the attestation must carry the same encryption public key.
	if regMsg.PublicKey != "" {
		if result.EncryptionPublicKey == "" {
			s.logger.Warn("attestation missing encryption key for registered public key",
				"provider_id", providerID,
			)
			result.Valid = false
			result.Error = "attestation missing encryption public key"
			provider.SetAttestationResult(&result)
			if policyConfigured {
				s.registry.MarkUntrusted(providerID)
			}
			return nil
		}
		if result.EncryptionPublicKey != regMsg.PublicKey {
			s.logger.Warn("attestation encryption key does not match register public key",
				"provider_id", providerID,
				"attestation_key", result.EncryptionPublicKey,
				"register_key", regMsg.PublicKey,
			)
			result.Valid = false
			result.Error = "encryption key mismatch"
			provider.SetAttestationResult(&result)
			if policyConfigured {
				s.registry.MarkUntrusted(providerID)
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
	if s.releases.BinaryHashEnforced() && policyConfigured {
		if result.BinaryHash == "" {
			s.logger.Warn("provider binary hash missing while known-good policy is configured",
				"provider_id", providerID,
			)
			result.Valid = false
			result.Error = "binary hash missing"
			provider.SetAttestationResult(&result)
			s.registry.MarkUntrusted(providerID)
			return nil
		}
		binaryHash, err := releases.NormalizeSHA256Hex(result.BinaryHash, "binary_hash")
		if err != nil || !knownBinaryHashes[binaryHash] {
			s.logger.Warn("provider binary hash not in known-good list",
				"provider_id", providerID,
				"binary_hash", result.BinaryHash,
			)
			result.Valid = false
			result.Error = "binary hash not recognized"
			provider.SetAttestationResult(&result)
			s.registry.MarkUntrusted(providerID)
			return nil
		}
		s.logger.Info("provider binary hash verified",
			"provider_id", providerID,
			"binary_hash", registry.TruncHash(result.BinaryHash),
		)
	}

	provider.SetAttested(true, registry.TrustSelfSigned)
	s.sendTrustStatus(provider, registry.TrustSelfSigned, "online", "SE attestation verified, awaiting MDM verification")

	// The SE attestation already proves SIP, Secure Boot, and binary hash —
	// the same checks a challenge re-verifies. Set LastChallengeVerified so
	// the provider is immediately routable. The 5-minute challenge cycle will
	// re-verify and add MDM cross-check for defense-in-depth.
	// Without this, a freshly connected provider waits up to 5 minutes before
	// it can serve any requests (until first challenge passes).
	provider.SetLastChallengeVerified(time.Now())

	s.logger.Info("provider attestation verified (self-signed)",
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
	restoreSerial := result.SerialNumber
	var expectedAccount []string
	if identityCandidate {
		restoreSerial = ""
		expectedAccount = []string{account}
	}
	if err := s.hooks.RestoreProviderState(ctx, provider, restoreSerial, result.PublicKey, expectedAccount...); err != nil {
		return err
	}

	// Independently recover the newest non-empty durable MDA chain. A newer
	// empty record must not shadow a chain earned by an earlier session. The
	// hardware-grant path still re-verifies the certificate and SE-key binding.
	//
	// Identity candidates stage it too, although their self-reported serial
	// restores no history and evicts no duplicate: the serial only selects a
	// CANDIDATE chain, never a grant. attachCachedMDAProof attaches it only
	// after this connection holds hardware trust, the chain re-verifies to
	// Apple's pinned root, its FreshnessCode equals SHA-256 of THIS
	// connection's SE key, and any Apple serial matches the attested one. A
	// chain earned by another machine's SE key can never bind here.
	s.stageDurableMDAChain(provider, result.SerialNumber)

	// Deduplicate: if another provider connection exists from the same physical
	// device (same serial number), disconnect it. This prevents multiple
	// provider processes on the same machine from registering independently
	// and competing for a single shared vllm-mlx backend.
	if !identityCandidate && result.SerialNumber != "" && !s.allowDuplicateProviderSerials {
		s.registry.DisconnectDuplicatesBySerial(providerID, result.SerialNumber)
	}

	// Persist provider state after attestation verification.
	// This captures the attestation result, serial number, and trust level.
	s.registry.PersistProvider(provider)

	// MDM verification is not spawned here. Registration binds stable device work
	// to the Server-owned bounded scheduler after attestation has established the
	// Secure Enclave identity and serial.
	if s.mdmClient != nil && result.SerialNumber == "" {
		s.logger.Warn("provider attestation has no serial number — cannot verify via MDM",
			"provider_id", providerID,
		)
	}
	return nil
}

// mdmVerifyOutcome classifies one scheduler-owned MDM verification attempt.
