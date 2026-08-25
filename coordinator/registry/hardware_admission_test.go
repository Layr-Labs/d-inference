package registry

import (
	"sync"
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

	if !reg.SetProviderHardwareAdmitted(provider, true) {
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

func TestExplicitRevocationFencesRoutingWhenThresholdGateDisabled(t *testing.T) {
	reg := New(testLogger())
	provider := reg.Register("revoked-disabled", nil, testRegisterMessage())
	if !reg.ProviderHardwareAdmitted(provider) {
		t.Fatal("disabled threshold gate should initially admit provider")
	}
	if !reg.SetProviderHardwareRevoked(provider, true) {
		t.Fatal("failed to apply live revocation")
	}
	if reg.ProviderHardwareAdmitted(provider) {
		t.Fatal("threshold rollback bypassed explicit revocation")
	}
}

func TestAdmissionCommitRejectsDisconnectedConnection(t *testing.T) {
	reg := New(testLogger())
	provider := reg.RegisterPendingHardwareAdmission(
		"disconnect-before-commit", nil, testRegisterMessage())
	reg.Disconnect(provider.ID)

	if reg.CommitProviderHardwareAdmission(provider) {
		t.Fatal("disconnected provider committed admission")
	}
	if provider.HardwareAdmissionStatus() || provider.PersistenceEnabled() {
		t.Fatal("stale provider gained admission or persistence")
	}
}

func TestStaleAdmissionCallbacksCannotMutateReplacementConnection(t *testing.T) {
	reg := New(testLogger())
	stale := reg.RegisterPendingHardwareAdmission(
		"reused-provider-id", nil, testRegisterMessage())
	reg.DisconnectProvider(stale)
	replacement := reg.RegisterPendingHardwareAdmission(
		stale.ID, nil, testRegisterMessage())

	if reg.SetProviderHardwareAdmitted(stale, true) {
		t.Fatal("stale callback mutated replacement admission")
	}
	if reg.ClaimProviderSerial(stale, "SERIAL-STALE") {
		t.Fatal("stale callback claimed a serial for replacement")
	}
	reg.DisconnectProvider(stale)
	if reg.GetProvider(replacement.ID) != replacement {
		t.Fatal("stale disconnect evicted replacement connection")
	}
	if replacement.HardwareAdmissionStatus() {
		t.Fatal("replacement inherited stale admission")
	}
}

func TestClaimProviderSerialKeepsFirstVerifiedOwner(t *testing.T) {
	reg := New(testLogger())
	first := reg.Register("first", nil, testRegisterMessage())
	second := reg.Register("second", nil, testRegisterMessage())
	first.SetAttestationResult(&attestation.VerificationResult{SerialNumber: "SERIAL-CLAIM"})
	second.SetAttestationResult(&attestation.VerificationResult{SerialNumber: " serial-claim "})

	if !reg.ClaimProviderSerial(first, "SERIAL-CLAIM") {
		t.Fatal("first verified claimant did not acquire serial")
	}
	if reg.ClaimProviderSerial(second, "SERIAL-CLAIM") {
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

	reg.DisconnectDuplicatesBySerial(legacy, "SERIAL-UPGRADE")
	// Re-register the future verified claimant because legacy dedup intentionally
	// evicted the duplicate under pre-enforcement semantics.
	verified = reg.Register("verified-owner-2", nil, testRegisterMessage())
	verified.SetAttestationResult(&attestation.VerificationResult{SerialNumber: "SERIAL-UPGRADE"})
	if !reg.ClaimProviderSerial(verified, "SERIAL-UPGRADE") {
		t.Fatal("legacy owner map blocked independently verified serial claim")
	}
	if reg.GetProvider(verified.ID) == nil {
		t.Fatal("verified owner was evicted by legacy serial state")
	}
	if reg.GetProvider(legacy.ID) != nil {
		t.Fatal("legacy serial owner survived verified replacement")
	}
}

func TestConcurrentVerifiedSerialClaimsLeaveOneOwner(t *testing.T) {
	for range 25 {
		reg := New(testLogger())
		first := reg.Register("first", nil, testRegisterMessage())
		second := reg.Register("second", nil, testRegisterMessage())
		first.SetAttestationResult(&attestation.VerificationResult{SerialNumber: "SERIAL-RACE"})
		second.SetAttestationResult(&attestation.VerificationResult{SerialNumber: "SERIAL-RACE"})

		start := make(chan struct{})
		results := make(chan bool, 2)
		var wg sync.WaitGroup
		for _, provider := range []*Provider{first, second} {
			wg.Add(1)
			go func(provider *Provider) {
				defer wg.Done()
				<-start
				results <- reg.ClaimProviderSerial(provider, "SERIAL-RACE")
			}(provider)
		}
		close(start)
		wg.Wait()
		close(results)
		successes := 0
		for result := range results {
			if result {
				successes++
			}
		}
		if successes != 1 {
			t.Fatalf("successful claims = %d, want exactly one", successes)
		}
		if reg.ProviderCount() != 1 {
			t.Fatalf("provider count = %d, want one owner", reg.ProviderCount())
		}
	}
}
