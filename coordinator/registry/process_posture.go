package registry

import (
	"bytes"

	"github.com/eigeninference/d-inference/coordinator/attestation"
)

// SetProcessPostureProof installs a certificate BEFORE granting hardware trust.
// The API verifies its Apple chain; this method atomically checks posture and
// the live identity so rotation/untrust cannot turn the proof into a bearer token.
func (p *Provider) SetProcessPostureProof(chain [][]byte, proof *attestation.MDAResult, seKey, processKey string, fresh bool, generation uint64) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.Status == StatusUntrusted || p.Status == StatusOffline ||
		p.AttestationResult == nil || !p.AttestationResult.Valid ||
		p.AttestationResult.PublicKey != seKey || p.PublicKey != processKey ||
		proof == nil || !proof.Valid || !proof.SIPStatusKnown || !proof.SecureBootStatusKnown ||
		!proof.SIPEnabled || !proof.SecureBootEnabled ||
		proof.DeviceSerial == "" || proof.DeviceSerial != p.AttestationResult.SerialNumber ||
		proof.DeviceUDID == "" {
		return false
	}
	want, err := attestation.ProcessPostureNonce(seKey, processKey, generation)
	if err != nil || !bytes.Equal(proof.FreshnessCode, want) {
		return false
	}
	p.MDAVerified, p.SEKeyBound = true, true
	p.MDACertChain, p.MDAResult = chain, proof
	p.processPostureFresh = fresh
	p.processPostureGeneration = generation
	return true
}

// ProcessPostureReady composes hardware posture with live possession of the
// SAME protected process key. A caller must still enforce durable revocation.
func (p *Provider) ProcessPostureReady() (udid string, fresh bool, ok bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.processPostureReadyLocked()
}

// RequireProcessPosture is armed for network registrations when the API policy
// enforces, including open mode and self-routing. Shadow does not arm this gate.
func (p *Provider) RequireProcessPosture() {
	p.mu.Lock()
	p.requireProcessPosture = true
	p.mu.Unlock()
}

// ProcessPostureGeneration pins durable recovery to the generation included in
// the certificate nonce, not a later generation observed just before a write.
func (p *Provider) ProcessPostureGeneration() uint64 {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.processPostureGeneration
}

func (p *Provider) processPostureReadyLocked() (udid string, fresh bool, ok bool) {
	if p.Status == StatusUntrusted || p.Status == StatusOffline ||
		!p.CodeAttested || !p.FreshCodeAttested || !p.ChallengeVerifiedSIP ||
		!p.MDAVerified || !p.SEKeyBound || p.AttestationResult == nil || !p.AttestationResult.Valid ||
		p.MDAResult == nil || !p.MDAResult.Valid ||
		!p.MDAResult.SIPStatusKnown || !p.MDAResult.SecureBootStatusKnown ||
		!p.MDAResult.SIPEnabled || !p.MDAResult.SecureBootEnabled ||
		p.MDAResult.DeviceSerial == "" || p.MDAResult.DeviceSerial != p.AttestationResult.SerialNumber ||
		p.MDAResult.DeviceUDID == "" {
		return "", false, false
	}
	want, err := attestation.ProcessPostureNonce(p.AttestationResult.PublicKey, p.PublicKey, p.processPostureGeneration)
	if err != nil || !bytes.Equal(p.MDAResult.FreshnessCode, want) {
		return "", false, false
	}
	return p.MDAResult.DeviceUDID, p.processPostureFresh, true
}
