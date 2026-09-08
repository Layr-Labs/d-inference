package api

import (
	"bytes"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

const processPosturePending = "awaiting Apple posture verification for this provider process"

// installProcessPosture is shared by synchronous and late MDA responses. Apple
// chain verification happens first; the registry atomically binds the result to
// the live process. Neither MDM SecurityInfo nor signed provider fields grant.
func (s *Server) installProcessPosture(provider *registry.Provider, ar attestation.VerificationResult, udid string, chain [][]byte, fresh bool) bool {
	if !s.processPostureEnforced() {
		s.observeProcessPosture(provider, ar, udid, chain, fresh, "proof_install")
		return false
	}
	proof, err := attestation.VerifyMDADeviceAttestation(chain)
	if err != nil || proof == nil || !proof.Valid {
		return false
	}
	return s.installVerifiedProcessPosture(provider, ar, udid, chain, proof, fresh)
}

// installVerifiedProcessPosture is only called after Apple chain validation.
// Separating verification lets late callbacks recheck ownership after crypto.
func (s *Server) installVerifiedProcessPosture(provider *registry.Provider, ar attestation.VerificationResult, udid string, chain [][]byte, proof *attestation.MDAResult, fresh bool) bool {
	if !s.processPostureEnforced() || proof == nil || !proof.Valid {
		return false
	}
	provider.Mu().Lock()
	processKey := provider.PublicKey
	provider.Mu().Unlock()
	generation, _ := s.trustReuseCache.revocationState(ar.PublicKey)
	want, err := attestation.ProcessPostureNonce(ar.PublicKey, processKey, generation)
	if err != nil || !bytes.Equal(proof.FreshnessCode, want) ||
		proof.DeviceSerial == "" || proof.DeviceSerial != ar.SerialNumber ||
		proof.DeviceUDID == "" || (udid != "" && proof.DeviceUDID != udid) {
		return false
	}
	if !proof.SIPStatusKnown || !proof.SecureBootStatusKnown {
		provider.SetMDMFailureReason("apple-posture-unavailable")
		return false
	}
	if !proof.SIPEnabled || !proof.SecureBootEnabled {
		provider.SetMDMFailureReason("posture-mismatch")
		s.registry.MarkUntrusted(provider.ID)
		return false
	}
	if !provider.SetProcessPostureProof(chain, proof, ar.PublicKey, processKey, fresh, generation) {
		return false
	}
	return s.completeProcessHardwareTrust(provider)
}

func (s *Server) completeProcessHardwareTrust(provider *registry.Provider) bool {
	if !s.processPostureEnforced() {
		return false
	}
	udid, fresh, ok := provider.ProcessPostureReady()
	if !ok {
		return false
	}
	ar := provider.GetAttestationResult()
	if ar == nil {
		return false
	}
	binary := providerApplicationBinaryHash(provider, ar.PublicKey, ar.BinaryHash)
	// Live grants always use the durable generation CAS. An identity-less
	// fallback cannot safely observe a concurrent revocation on another server.
	if binary == "" {
		return false
	}
	if !s.recordTrustReuseAtGeneration(provider, ar.PublicKey, ar.SerialNumber, binary, true, true, udid, fresh, provider.ProcessPostureGeneration()) {
		return false
	}
	provider.SetMDMFailureReason("")
	s.sendTrustStatus(provider, registry.TrustHardware, "online", "Apple posture and process identity verified")
	s.registry.PersistProvider(provider)
	return true
}

// processCodeProofSettled runs after the encrypted nonce was consumed. Holding
// MDM work until this point avoids a herd during coordinator restarts: surviving
// processes finish entirely over the WebSocket using their original key.
func (s *Server) processCodeProofSettled(providerID string, provider *registry.Provider) {
	if !s.processPostureEnforced() {
		if ar := provider.GetAttestationResult(); ar != nil {
			s.observeProcessPosture(provider, *ar, "", provider.StagedMDAChain(), false, "code_proof")
		}
		return
	}
	resumed := s.completeProcessHardwareTrust(provider)
	if !resumed {
		if ar := provider.GetAttestationResult(); ar != nil {
			resumed = s.attachCachedMDAProof(providerID, provider, *ar)
		}
	}
	if s.mdmScheduler != nil {
		if !resumed {
			s.mdmScheduler.PromoteFailedFastSkip(provider)
		}
		s.mdmScheduler.ChallengeSettled(provider, resumed)
	}
}
