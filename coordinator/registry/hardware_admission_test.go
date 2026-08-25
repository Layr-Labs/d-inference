package registry

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
)

func TestHardwareAdmissionGateCannotBeRelaxedBySelfRoute(t *testing.T) {
	reg := New(testLogger())
	reg.SetHardwareAdmissionEnforced(true)
	msg := testRegisterMessage()
	provider := reg.Register("pending-hardware", nil, msg)
	provider.mu.Lock()
	provider.RuntimeVerified = true
	provider.LastChallengeVerified = time.Now()
	provider.ChallengeVerifiedSIP = true
	provider.mu.Unlock()

	provider.mu.Lock()
	if reg.providerLivenessGateLocked(provider, TrustNone, true, time.Now()) {
		provider.mu.Unlock()
		t.Fatal("owner self-route bypassed hardware admission")
	}
	provider.mu.Unlock()

	if !reg.SetProviderHardwareAdmitted(provider.ID, true) {
		t.Fatal("failed to mark provider admitted")
	}
	provider.mu.Lock()
	if !reg.providerLivenessGateLocked(provider, TrustNone, true, time.Now()) {
		provider.mu.Unlock()
		t.Fatal("admitted owner provider failed liveness gate")
	}
	provider.mu.Unlock()
}

func TestDisabledHardwareAdmissionPreservesRegistrationDefault(t *testing.T) {
	reg := New(testLogger())
	provider := reg.Register("legacy-default", nil, testRegisterMessage())
	if !provider.HardwareAdmissionStatus() {
		t.Fatal("disabled hardware policy changed legacy registration behavior")
	}
}

func TestPendingRegistrationStartsUnadmittedEvenBeforeEnforcement(t *testing.T) {
	reg := New(testLogger())
	provider := reg.RegisterPendingHardwareAdmission(
		"pending-before-policy-flip", nil, testRegisterMessage())
	if provider.HardwareAdmissionStatus() {
		t.Fatal("pending registration inherited fail-open admission")
	}
	if provider.PersistenceEnabled() {
		t.Fatal("pending registration enabled persistence before admission")
	}
}

func TestClaimProviderSerialKeepsFirstVerifiedOwner(t *testing.T) {
	reg := New(testLogger())
	first := reg.Register("first", nil, testRegisterMessage())
	second := reg.Register("second", nil, testRegisterMessage())
	first.SetAttestationResult(&attestation.VerificationResult{SerialNumber: "SERIAL-CLAIM"})
	second.SetAttestationResult(&attestation.VerificationResult{SerialNumber: "SERIAL-CLAIM"})

	if !reg.ClaimProviderSerial(first.ID, "SERIAL-CLAIM") {
		t.Fatal("first verified claimant did not acquire serial")
	}
	if reg.ClaimProviderSerial(second.ID, "SERIAL-CLAIM") {
		t.Fatal("second claimant replaced live serial owner")
	}
	if reg.GetProvider(first.ID) == nil {
		t.Fatal("first serial owner was evicted")
	}
	if reg.GetProvider(second.ID) != nil {
		t.Fatal("duplicate serial claimant remained connected")
	}
}

func TestVerifiedSerialClaimReplacesLegacyOwnerMap(t *testing.T) {
	reg := New(testLogger())
	legacy := reg.Register("legacy-owner", nil, testRegisterMessage())
	verified := reg.Register("verified-owner", nil, testRegisterMessage())
	legacy.SetAttestationResult(&attestation.VerificationResult{SerialNumber: "SERIAL-UPGRADE"})
	verified.SetAttestationResult(&attestation.VerificationResult{SerialNumber: "SERIAL-UPGRADE"})

	reg.DisconnectDuplicatesBySerial(legacy.ID, "SERIAL-UPGRADE")
	// Re-register the future verified claimant because legacy dedup intentionally
	// evicted the duplicate under pre-enforcement semantics.
	verified = reg.Register("verified-owner-2", nil, testRegisterMessage())
	verified.SetAttestationResult(&attestation.VerificationResult{SerialNumber: "SERIAL-UPGRADE"})
	if !reg.ClaimProviderSerial(verified.ID, "SERIAL-UPGRADE") {
		t.Fatal("legacy owner map blocked independently verified serial claim")
	}
	if reg.GetProvider(verified.ID) == nil {
		t.Fatal("verified owner was evicted by legacy serial state")
	}
	if reg.GetProvider(legacy.ID) != nil {
		t.Fatal("legacy serial owner survived verified replacement")
	}
}
