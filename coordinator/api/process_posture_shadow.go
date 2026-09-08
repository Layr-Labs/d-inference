package api

import (
	"bytes"
	"crypto/sha256"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// processPostureObservation is a counterfactual snapshot, never an authorization
// input. Its bounded reasons do not contain device identity or certificate data.
type processPostureObservation struct {
	allowed bool
	reason  string
}

// evaluateProcessPosture reads the strict candidate inputs without installing a
// proof, changing scheduler state, issuing Apple requests, or writing evidence.
// It evaluates available evidence only: absence is not proof of bad posture.
func (s *Server) evaluateProcessPosture(p *registry.Provider, ar attestation.VerificationResult, udid string, chain [][]byte, fresh bool) processPostureObservation {
	block := func(reason string) processPostureObservation { return processPostureObservation{reason: reason} }
	if p == nil || !ar.Valid || ar.PublicKey == "" || ar.SerialNumber == "" {
		return block("missing_identity")
	}
	p.Mu().Lock()
	processKey, status := p.PublicKey, p.Status
	code, freshCode, signedSIP := p.CodeAttested, p.FreshCodeAttested, p.ChallengeVerifiedSIP
	liveAR := p.AttestationResult
	identityMatches := liveAR != nil && liveAR.Valid && liveAR.PublicKey == ar.PublicKey && liveAR.SerialNumber == ar.SerialNumber
	token := p.APNsDeviceToken
	p.Mu().Unlock()
	if !identityMatches {
		return block("identity_changed")
	}
	if status == registry.StatusOffline || status == registry.StatusUntrusted {
		return block("inactive")
	}
	if s.trustReuseCache == nil {
		return block("evidence_unavailable")
	}
	if blocked, _ := s.trustSafetyStatus(); blocked || s.trustReuseIdentityPending(ar.PublicKey) {
		return block("revocation_safety")
	}
	generation, _ := s.trustReuseCache.revocationState(ar.PublicKey)
	if !fresh && s.trustReuseCache.isRevoked(ar.PublicKey) {
		return block("revoked")
	}
	if len(chain) == 0 {
		return block("missing_proof")
	}
	proof, err := attestation.VerifyMDADeviceAttestation(chain)
	if err != nil || proof == nil || !proof.Valid {
		return block("invalid_chain")
	}
	want, err := attestation.ProcessPostureNonce(ar.PublicKey, processKey, generation)
	if err != nil {
		return block("missing_identity")
	}
	if !bytes.Equal(proof.FreshnessCode, want) {
		legacy := sha256.Sum256([]byte(ar.PublicKey))
		if bytes.Equal(proof.FreshnessCode, legacy[:]) {
			return block("legacy_nonce")
		}
		return block("nonce_mismatch")
	}
	if proof.DeviceSerial == "" || proof.DeviceSerial != ar.SerialNumber {
		return block("serial_mismatch")
	}
	if proof.DeviceUDID == "" || (udid != "" && proof.DeviceUDID != udid) {
		return block("device_identifier_mismatch")
	}
	if !proof.SIPStatusKnown || !proof.SecureBootStatusKnown {
		return block("posture_unavailable")
	}
	if !proof.SIPEnabled || !proof.SecureBootEnabled {
		return block("posture_mismatch")
	}
	if !code || !freshCode || !signedSIP {
		return block("process_proof_missing")
	}
	// Baseline cross-version resumption may prove a newly supplied process key.
	// That proof must never look like exact-key continuity in shadow reporting.
	if s.codeAttestThrottle == nil || !s.codeAttestThrottle.reuseProcessIdentity(ar.PublicKey, token, processKey) {
		return block("process_identity_unproven")
	}
	if providerApplicationBinaryHash(p, ar.PublicKey, ar.BinaryHash) == "" {
		return block("application_identity_missing")
	}
	return processPostureObservation{allowed: true, reason: "ready"}
}

func (s *Server) observeProcessPosture(p *registry.Provider, ar attestation.VerificationResult, udid string, chain [][]byte, fresh bool, source string) processPostureObservation {
	observation := s.evaluateProcessPosture(p, ar, udid, chain, fresh)
	// All callers use a fixed source. Keep the metric label bounded even when a
	// future call site accidentally passes dynamic text.
	switch source {
	case "security_info", "late_security_info", "cached_mda", "trust_reuse", "proof_install", "code_proof", "fresh_mda", "late_mda":
	default:
		source = "other"
	}
	decision := "would_block"
	if observation.allowed {
		decision = "would_pass"
	}
	labels := []MetricLabel{{"mode", string(s.processPostureMode.normalized())}, {"source", source}, {"decision", decision}, {"reason", observation.reason}}
	if s.metrics != nil {
		s.metrics.IncCounter("process_posture_evaluations_total", labels...)
	}
	s.ddIncr("process_posture.evaluations", []string{"mode:" + string(s.processPostureMode.normalized()), "source:" + source, "decision:" + decision, "reason:" + observation.reason})
	return observation
}
