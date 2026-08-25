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
