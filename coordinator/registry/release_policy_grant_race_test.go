package registry

import (
	"fmt"
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
// live, a release-policy sweep advances to generation 2, and only then does
// the old challenge's grant land. The required-policy sweep reports the
// evidence-less provider so the caller kicks it — but that kick may already be
// consumed by the very challenge whose stale grant is in flight, so the grant
// must ALSO be refused atomically under the registry lock AND kick the
// provider again for an immediate out-of-band re-challenge — otherwise the
// provider idles with stale-generation, unroutable evidence until the
// periodic ticker. A grant carrying the current generation must be accepted.
func TestStaleGenerationGrantRefusedAndKickedAfterSweep(t *testing.T) {
	reg := New(testLogger())
	p, staleEvidence := grantRaceProvider(t, reg, "race-provider")

	// Generation 1 is live when the challenge derives its evidence.
	reg.SetReleasePolicyGeneration(1, true, nil)
	staleEvidence.PolicyGeneration = 1

	// The sweep to generation 2 runs BEFORE the grant lands. A REQUIRED-policy
	// sweep reports every provider not carried forward — even one holding no
	// evidence yet — so the caller can kick it.
	if needChallenge := reg.SetReleasePolicyGeneration(2, true, nil); len(needChallenge) != 1 || needChallenge[0] != p.ID {
		t.Fatalf("required-policy sweep must report the evidence-less provider, got %v", needChallenge)
	}
	// Kicking is the caller's job; the sweep itself must not touch the kick
	// channel. Model the worst case: the in-flight challenge already consumed
	// the caller's kick before its stale grant lands.
	select {
	case <-p.ImmediateChallengeChan():
		t.Fatal("the sweep itself must not kick; that is the caller's job")
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

// TestFirstRequiredPolicyActivationKicksEvidencelessFleet covers the
// activation cliff: under a non-required policy no provider ever needed (or
// could have produced) application evidence, so when the first release row
// flips the policy to REQUIRED the whole connected fleet is evidence-less and
// unroutable. The sweep must report every provider not carried forward —
// including those with no prior evidence — so the caller kicks an immediate
// challenge for each instead of derouting the fleet until the 5-minute ticker
// (the 120s request queue would drain first). Non-required sweeps stay
// kick-free and carried-forward providers are never re-kicked.
func TestFirstRequiredPolicyActivationKicksEvidencelessFleet(t *testing.T) {
	reg := New(testLogger())
	const fleet = 3
	providers := make([]*Provider, 0, fleet)
	templates := make([]ApplicationEvidence, 0, fleet)
	for i := range fleet {
		p, evidence := grantRaceProvider(t, reg, fmt.Sprintf("provider-%d", i))
		providers = append(providers, p)
		templates = append(templates, evidence)
	}

	// Pre-activation, non-required snapshot: nobody holds evidence and nobody
	// is kicked.
	if kicks := reg.SetReleasePolicyGeneration(1, false, nil); len(kicks) != 0 {
		t.Fatalf("non-required sweep over an evidence-less fleet reported %v", kicks)
	}

	// First REQUIRED activation: every connected provider must be reported
	// even though none holds evidence to invalidate.
	needChallenge := reg.SetReleasePolicyGeneration(2, true, nil)
	if len(needChallenge) != fleet {
		t.Fatalf("first required activation reported %d providers, want all %d: %v",
			len(needChallenge), fleet, needChallenge)
	}
	// Mirror the production caller (SyncBinaryHashes): kick each reported
	// provider, then verify every fleet member has an immediate challenge
	// pending — evidence regeneration must not wait for the periodic ticker.
	for _, id := range needChallenge {
		provider := reg.GetProvider(id)
		if provider == nil {
			t.Fatalf("sweep reported unknown provider %q", id)
		}
		provider.RequestImmediateChallenge()
	}
	for _, p := range providers {
		select {
		case <-p.ImmediateChallengeChan():
		default:
			t.Fatalf("provider %s got no immediate challenge after required activation", p.ID)
		}
	}

	// The kicked challenges complete against the new snapshot: evidence at the
	// current generation is accepted.
	for i, p := range providers {
		evidence := templates[i]
		evidence.PolicyGeneration = 2
		if !p.GrantApplicationEvidenceIfNotUntrusted(evidence) {
			t.Fatalf("provider %s: current-generation grant refused", p.ID)
		}
	}

	// Routine required refresh with still-approved evidence: carried forward,
	// re-stamped at the new generation, and NOT re-kicked.
	if kicks := reg.SetReleasePolicyGeneration(3, true,
		func(ApplicationEvidence) bool { return true }); len(kicks) != 0 {
		t.Fatalf("carried-forward providers must not be reported, got %v", kicks)
	}
	for _, p := range providers {
		evidence, ok := p.ApplicationEvidenceSnapshot()
		if !ok || evidence.PolicyGeneration != 3 {
			t.Fatalf("provider %s: carried-forward evidence = %+v ok=%v, want re-stamp at generation 3",
				p.ID, evidence, ok)
		}
		select {
		case <-p.ImmediateChallengeChan():
			t.Fatalf("provider %s: carried-forward provider must not be kicked", p.ID)
		default:
		}
	}

	// Deactivation back to non-required: even though nothing is carried
	// forward and all evidence is cleared, no kicks — evidence is no longer a
	// routing gate, so the periodic ticker is soon enough.
	if kicks := reg.SetReleasePolicyGeneration(4, false, nil); len(kicks) != 0 {
		t.Fatalf("non-required sweep must be kick-free, got %v", kicks)
	}
	for _, p := range providers {
		if _, ok := p.ApplicationEvidenceSnapshot(); ok {
			t.Fatalf("provider %s: evidence must still be cleared by a non-required sweep", p.ID)
		}
	}
}
