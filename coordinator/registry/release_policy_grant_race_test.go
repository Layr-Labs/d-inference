package registry

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/attestation"
)

// grantRaceProvider registers a provider that satisfies every
// GrantApplicationEvidenceIfNotUntrusted field binding for the returned
// evidence template, so only the policy-generation check can decide the
// outcome (tokenless grants are covered separately by the api-level tests).
func grantRaceProvider(t *testing.T, reg *Registry, id string) (*Provider, ApplicationEvidence) {
	t.Helper()
	p := reg.Register(id, nil, testRegisterMessage())
	p.mu.Lock()
	p.Version = "2.0.0"
	p.APNsDeviceToken = "race-apns-token"
	p.RuntimeVerified = true
	p.RuntimeManifestChecked = true
	p.MetallibVerified = true
	p.AttestationResult = &attestation.VerificationResult{
		Valid: true, PublicKey: "se-key", SerialNumber: "SERIAL",
	}
	p.mu.Unlock()
	return p, ApplicationEvidence{
		SEPublicKey: "se-key", Serial: "SERIAL",
		ProcessPublicKey: p.PublicKey, APNsToken: "race-apns-token",
		BinaryHash: "hash", Version: "2.0.0", Backend: BackendMLXSwift,
	}
}

// TestStaleGenerationGrantRefusedAndKickedAfterSweep is the deterministic
// clear/derive/grant race: a challenge derives evidence while generation 1 is
// live, a release-policy sweep advances to generation 2 (the provider holds no
// evidence yet, so the sweep cannot report it for re-challenge), and only then
// does the old challenge's grant land. The grant must be refused atomically
// under the registry lock AND kick the provider for an immediate out-of-band
// re-challenge — otherwise the provider idles with stale-generation,
// unroutable evidence until the periodic ticker. A grant carrying the current
// generation must be accepted.
func TestStaleGenerationGrantRefusedAndKickedAfterSweep(t *testing.T) {
	reg := New(testLogger())
	p, staleEvidence := grantRaceProvider(t, reg, "race-provider")

	// Generation 1 is live when the challenge derives its evidence.
	reg.SetReleasePolicyGeneration(1, true, nil)
	staleEvidence.PolicyGeneration = 1

	// The sweep to generation 2 runs BEFORE the grant lands. The provider has
	// no evidence, so it is not in the invalidated set and receives no kick.
	if invalidated := reg.SetReleasePolicyGeneration(2, true, nil); len(invalidated) != 0 {
		t.Fatalf("sweep of an evidence-less provider reported %v", invalidated)
	}
	select {
	case <-p.ImmediateChallengeChan():
		t.Fatal("the sweep itself must not kick an evidence-less provider")
	default:
	}

	// The old challenge completes: its stale-generation grant is refused and
	// triggers the same immediate re-challenge a sweep invalidation would.
	if p.GrantApplicationEvidenceIfNotUntrusted(staleEvidence) {
		t.Fatal("grant with a stale policy generation must be refused after the sweep")
	}
	if _, ok := p.ApplicationEvidenceSnapshot(); ok {
		t.Fatal("a refused stale-generation grant must not install evidence")
	}
	select {
	case <-p.ImmediateChallengeChan():
	default:
		t.Fatal("a refused stale-generation grant must kick an immediate re-challenge")
	}

	// The re-challenge derives from the current snapshot: accepted.
	currentEvidence := staleEvidence
	currentEvidence.PolicyGeneration = 2
	if !p.GrantApplicationEvidenceIfNotUntrusted(currentEvidence) {
		t.Fatal("grant with the current policy generation must be accepted")
	}
	if evidence, ok := p.ApplicationEvidenceSnapshot(); !ok || evidence.PolicyGeneration != 2 {
		t.Fatalf("installed evidence = %+v ok=%v, want policy generation 2", evidence, ok)
	}
	select {
	case <-p.ImmediateChallengeChan():
		t.Fatal("an accepted grant must not request a re-challenge")
	default:
	}
}

// TestConcurrentSweepAndGrantNeverStrandStaleEvidence hammers the same race
// non-deterministically: after every sweep/grant interleaving, the provider
// either holds evidence at the CURRENT generation or holds none but has an
// immediate re-challenge pending — never stale evidence with no kick.
func TestConcurrentSweepAndGrantNeverStrandStaleEvidence(t *testing.T) {
	reg := New(testLogger())
	p, evidence := grantRaceProvider(t, reg, "race-provider")
	reg.SetReleasePolicyGeneration(1, true, nil)

	for generation := uint64(2); generation < 200; generation++ {
		granting := evidence
		granting.PolicyGeneration = generation - 1
		done := make(chan bool, 1)
		go func() {
			done <- p.GrantApplicationEvidenceIfNotUntrusted(granting)
		}()
		// Mirror the production caller (SyncBinaryHashes): providers the sweep
		// invalidated are kicked for an immediate re-challenge.
		for _, id := range reg.SetReleasePolicyGeneration(generation, true, nil) {
			if id == p.ID {
				p.RequestImmediateChallenge()
			}
		}
		granted := <-done

		installed, ok := p.ApplicationEvidenceSnapshot()
		kicked := false
		select {
		case <-p.ImmediateChallengeChan():
			kicked = true
		default:
		}
		if ok && installed.PolicyGeneration != generation {
			t.Fatalf("generation %d: stranded stale evidence %+v (granted=%v kicked=%v)",
				generation, installed, granted, kicked)
		}
		if !ok && !kicked {
			t.Fatalf("generation %d: no evidence and no re-challenge kick (granted=%v)",
				generation, granted)
		}
	}
}
