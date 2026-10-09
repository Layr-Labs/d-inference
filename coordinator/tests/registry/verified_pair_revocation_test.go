package registry_test

// Ported from the research branch's in-package
// TestVerifiedPairRevocationClosesGrantWithoutResurrection, through the public
// registry API only. Losing trust or release evidence on a member connection
// must close the pair grant at once, not at the next periodic revalidation,
// and a later recovery must never revive it. The device hold is quarantined,
// never freed, because an owner may already be running.

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func requirePairRevoked(t *testing.T, r *production.Registry, h *production.VerifiedPairHandle) {
	t.Helper()
	select {
	case <-h.Done():
	default:
		t.Fatal("pair invalidation was not published")
	}
	if _, err := r.ValidateVerifiedPair(h); err == nil {
		t.Fatal("revoked grant resurrected")
	}
	status, err := r.VerifiedPairStatus(h)
	if err != nil || status.Phase != production.VerifiedPairQuarantined {
		t.Fatalf("revocation freed a possible native owner: phase=%q err=%v", status.Phase, err)
	}
}

func TestVerifiedPairRevocationClosesGrantWithoutResurrection(t *testing.T) {
	cases := map[string]func(*production.Registry, *production.Provider){
		"hard_untrust": func(r *production.Registry, p *production.Provider) { r.MarkUntrusted(p.ID) },
		"transient_untrust": func(r *production.Registry, p *production.Provider) {
			r.MarkUntrustedTransient(p.ID)
			r.RecordChallengeSuccess(p.ID)
		},
		"challenge_failure": func(r *production.Registry, p *production.Provider) { r.RecordChallengeFailure(p.ID, false) },
		"challenge_timeouts_at_limit": func(r *production.Registry, p *production.Provider) {
			for range production.MaxFailedChallenges {
				r.RecordChallengeFailure(p.ID, true)
			}
		},
		"code_clear":       func(_ *production.Registry, p *production.Provider) { p.SetCodeAttested(false) },
		"attestation_lost": func(_ *production.Registry, p *production.Provider) { p.SetAttested(false, production.TrustNone) },
		"sip_lost":         func(_ *production.Registry, p *production.Provider) { p.SetChallengeVerifiedSIP(false) },
		"trust_downgrade": func(r *production.Registry, p *production.Provider) {
			r.SetTrustLevel(p.ID, production.TrustSelfSigned)
		},
		"policy_generation": func(r *production.Registry, _ *production.Provider) {
			r.SetReleasePolicyGeneration(8, true, func(production.ApplicationEvidence) bool { return true })
		},
	}
	for name, revoke := range cases {
		t.Run(name, func(t *testing.T) {
			r := pairEnvironment(t)
			h, _, members := committedPairFixture(t, r)
			revoke(r, members[0])
			requirePairRevoked(t, r, h)
		})
	}
}

// The same entry points must leave a grant alone when nothing was lost:
// re-asserting trust, a challenge timeout below the deroute limit, or a
// periodic challenge that verifies. The challenge verifier clears release
// evidence on entry and grants it again when the response verifies; a failed
// verification revokes through the failure and untrust paths above.
func TestVerifiedPairSurvivesTrustRefreshAndSingleChallengeTimeout(t *testing.T) {
	cases := map[string]func(*production.Registry, *production.Provider){
		"release_evidence_reverified": func(_ *production.Registry, p *production.Provider) {
			p.ClearApplicationEvidence()
			trustPairDevice(t, p, "serial-a", pairDeviceSEKey("serial-a"), &protocol.BackendCapacity{TotalMemoryGB: 64})
		},
		"attestation_reasserted": func(_ *production.Registry, p *production.Provider) {
			p.SetAttested(true, production.TrustHardware)
		},
		"sip_reasserted":  func(_ *production.Registry, p *production.Provider) { p.SetChallengeVerifiedSIP(true) },
		"code_reasserted": func(_ *production.Registry, p *production.Provider) { p.SetCodeAttested(true) },
		"trust_reasserted": func(r *production.Registry, p *production.Provider) {
			r.SetTrustLevel(p.ID, production.TrustHardware)
		},
		"challenge_timeouts_below_limit": func(r *production.Registry, p *production.Provider) {
			for range production.MaxFailedChallenges - 1 {
				r.RecordChallengeFailure(p.ID, true)
			}
		},
	}
	for name, refresh := range cases {
		t.Run(name, func(t *testing.T) {
			r := pairEnvironment(t)
			h, _, members := committedPairFixture(t, r)
			refresh(r, members[0])
			select {
			case <-h.Done():
				t.Fatal("grant revoked although no trust or evidence was lost")
			default:
			}
			if _, err := r.ValidateVerifiedPair(h); err != nil {
				t.Fatalf("active grant no longer validates: %v", err)
			}
		})
	}
}

// Runtime policy paths clear these flags and reconcile without MarkUntrusted.
// An unchanged refresh keeps the grant; a loss closes it and a later
// restoration does not revive it.
func TestVerifiedPairRuntimePolicyLossIsNotRevivedByRestore(t *testing.T) {
	r := pairEnvironment(t)
	h, _, members := committedPairFixture(t, r)
	if err := r.ReconcileAttestedRuntimeCapabilities(members[0].ID); err != nil {
		t.Fatal(err)
	}
	select {
	case <-h.Done():
		t.Fatal("successful unchanged refresh revoked pair")
	default:
	}
	setRuntimePolicy := func(verified bool) {
		members[0].Mu().Lock()
		members[0].RuntimeVerified, members[0].RuntimeManifestChecked, members[0].MetallibVerified = verified, verified, verified
		members[0].Mu().Unlock()
		if err := r.ReconcileAttestedRuntimeCapabilities(members[0].ID); err != nil {
			t.Fatal(err)
		}
	}
	setRuntimePolicy(false)
	select {
	case <-h.Done():
	default:
		t.Fatal("pair invalidation was not published")
	}
	setRuntimePolicy(true)
	if _, err := r.ValidateVerifiedPair(h); err == nil {
		t.Fatal("runtime policy restoration revived old grant")
	}
}
