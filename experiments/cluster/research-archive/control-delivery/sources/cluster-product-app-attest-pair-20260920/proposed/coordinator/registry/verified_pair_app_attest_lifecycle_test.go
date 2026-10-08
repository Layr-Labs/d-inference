package registry

import (
	"encoding/base64"
	"testing"
	"time"
)

func TestVerifiedPairAppAttestExpiryWakesIdleOwnerAndKeepsHolds(t *testing.T) {
	r, p, request, leases := appAttestPairFixture(t)
	leases[0].ValidUntil = time.Now().Add(500 * time.Millisecond)
	if !r.GrantAppAttestServingAuthorization(p[0], leases[0]) {
		t.Fatal("short current lease")
	}
	h, _ := pairTestActive(t, r, p, request)
	select {
	case <-h.Done():
	case <-time.After(2 * time.Second):
		t.Fatal("idle lease expiry never woke owner")
	}
	pairTestRequirePhase(t, r, h, VerifiedPairQuarantined)
	r.mu.RLock()
	held := len(r.verifiedPairs.devices)
	r.mu.RUnlock()
	if held == 0 {
		t.Fatal("expiry released active ownership")
	}
}
func TestVerifiedPairAppAttestRefreshPreservesIdentityButNotOriginalLifetime(t *testing.T) {
	r, p, request, leases := appAttestPairFixture(t)
	leases[0].ValidUntil = time.Now().Add(500 * time.Millisecond)
	if !r.GrantAppAttestServingAuthorization(p[0], leases[0]) {
		t.Fatal("short current lease")
	}
	h, m := pairTestActive(t, r, p, request)
	leases[0].ValidUntil = time.Now().Add(30 * time.Second)
	if !r.GrantAppAttestServingAuthorization(p[0], leases[0]) {
		t.Fatal("same-proof renewal")
	}
	select {
	case <-h.Done():
		t.Fatal("old expiry canceled renewed proof")
	case <-time.After(550 * time.Millisecond):
	}
	if got, err := r.ValidateVerifiedPair(h); err != nil || got != m {
		t.Fatal("renewal changed original authority", err)
	}
	r.mu.Lock()
	unlock := lockVerifiedPairMembers(p)
	err := r.validateVerifiedPairLocked(h.state, m.ExpiresAt, false)
	unlock()
	r.mu.Unlock()
	if err == nil {
		t.Fatal("renewal extended fixed session deadline")
	}
	pairTestDone(t, h)
}
func TestVerifiedPairAppAttestLeaseAndPolicyChangesEndExactState(t *testing.T) {
	for _, kind := range []string{"clear", "disable", "policy", "credential", "proof-renewal", "machine", "hard-untrust", "hard-challenge", "sip", "release-generation"} {
		t.Run(kind, func(t *testing.T) {
			r, p, request, leases := appAttestPairFixture(t)
			h, _ := pairTestActive(t, r, p, request)
			switch kind {
			case "clear":
				r.ClearAppAttestServingAuthorization(p[0])
			case "disable":
				r.SetAppAttestServingPolicy(false, 7)
			case "policy":
				r.SetAppAttestServingPolicy(true, 8)
			case "credential":
				r.RevokeAppAttestCredential(leases[0].CredentialID)
			case "proof-renewal":
				leases[0].ProofSessionID = "replacement"
				if !r.GrantAppAttestServingAuthorization(p[0], leases[0]) {
					t.Fatal("new ordinary proof grant")
				}
			case "machine":
				if !r.BindVerifiedMachineIdentity(p[0], leases[0].AccountID, "new-machine") {
					t.Fatal("new verified inventory binding")
				}
			case "hard-untrust":
				r.MarkUntrusted(p[0].ID)
			case "hard-challenge":
				r.RecordChallengeFailure(p[0].ID, false)
			case "sip":
				p[0].SetChallengeVerifiedSIP(false)
			case "release-generation":
				r.SetReleasePolicyGeneration(8, true, nil)
			}
			pairTestDone(t, h)
			pairTestRequirePhase(t, r, h, VerifiedPairQuarantined)
		})
	}
}
func TestVerifiedPairAppAttestIndependentLegacyLossDoesNotEndAuthority(t *testing.T) {
	r, p, request, _ := appAttestPairFixture(t)
	h, _ := pairTestActive(t, r, p, request)
	p[0].SetAttested(false, TrustNone)
	p[0].SetCodeAttested(false)
	p[0].ClearApplicationEvidence()
	r.MarkUntrustedTransient(p[0].ID)
	for i := 0; i < MaxFailedChallenges; i++ {
		r.RecordChallengeFailure(p[0].ID, true)
	}
	if _, err := r.ValidateVerifiedPair(h); err != nil {
		t.Fatal("legacy-only proof loss revoked qualified AA", err)
	}
	select {
	case <-h.Done():
		t.Fatal("independent authority terminated")
	default:
	}
}
func TestVerifiedPairAppAttestReconnectMachineAndPointAliasesStayHeld(t *testing.T) {
	for _, kind := range []string{"machine", "point", "same-id"} {
		t.Run(kind, func(t *testing.T) {
			r, p, request, leases := appAttestPairFixture(t)
			h, m := pairTestActive(t, r, p, request)
			r.Disconnect(p[0].ID)
			aliasID := "alias"
			if kind == "same-id" {
				aliasID = p[0].ID
			}
			alias := pairTestMember(t, r, aliasID, "new-genuine-serial")
			machine := "other-machine"
			if kind == "machine" || kind == "same-id" {
				machine = leases[0].MachineID
			}
			pairTestAppAttest(t, r, alias, machine)
			if kind == "point" {
				raw, _ := base64.StdEncoding.DecodeString(m.Members[0].controlPublicKey())
				alias.mu.Lock()
				alias.AttestationResult.PublicKey = base64.StdEncoding.EncodeToString(raw[1:])
				alias.appAttestAuthorization.VerifiedControlPublicKey = alias.AttestationResult.PublicKey
				alias.mu.Unlock()
			}
			pairTestDone(t, h)
			r.mu.RLock()
			alias.mu.Lock()
			held := r.providerPairHeldLocked(alias, time.Now(), nil)
			alias.mu.Unlock()
			r.mu.RUnlock()
			if !held {
				t.Fatal("new connection evaded retained physical identity")
			}
			if err := r.ObserveVerifiedPairOwnerReleased(h, alias, m.TranscriptSHA256); err == nil {
				t.Fatal("replacement consumed original cleanup")
			}
			// A missing/expired lease cannot erase the conservative reconnect hold.
			r.ClearAppAttestServingAuthorization(alias)
			r.mu.RLock()
			alias.mu.Lock()
			held = r.providerPairHeldLocked(alias, time.Now(), nil)
			alias.mu.Unlock()
			r.mu.RUnlock()
			if !held {
				t.Fatal("proof loss erased hold")
			}
		})
	}
}
func TestVerifiedPairAppAttestReleaseRequiresOriginalCurrentProof(t *testing.T) {
	r, p, request, leases := appAttestPairFixture(t)
	h, m := pairTestActive(t, r, p, request)
	wrong := m.TranscriptSHA256
	wrong[0] ^= 1
	if err := r.ObserveVerifiedPairOwnerReleased(h, p[0], wrong); err == nil {
		t.Fatal("wrong transcript release")
	}
	r.ClearAppAttestServingAuthorization(p[0])
	if err := r.ObserveVerifiedPairOwnerReleased(h, p[0], m.TranscriptSHA256); err == nil {
		t.Fatal("unqualified cleanup erased hold")
	}
	if !r.GrantAppAttestServingAuthorization(p[0], leases[0]) {
		t.Fatal("same original authority refresh")
	}
	pairTestRequirePhase(t, r, h, VerifiedPairQuarantined)
	for _, member := range p {
		if err := r.ObserveVerifiedPairOwnerReleased(h, member, m.TranscriptSHA256); err != nil {
			t.Fatal(err)
		}
	}
	pairTestRequirePhase(t, r, h, VerifiedPairReleased)
}

func TestVerifiedPairAppAttestProofRenewalDischargesOnlyOriginalCleanup(t *testing.T) {
	r, p, request, leases := appAttestPairFixture(t)
	h, m := pairTestActive(t, r, p, request)
	leases[0].ProofSessionID = "retry-proof"
	if !r.GrantAppAttestServingAuthorization(p[0], leases[0]) {
		t.Fatal("fresh same-connection proof")
	}
	pairTestDone(t, h)
	pairTestRequirePhase(t, r, h, VerifiedPairQuarantined)
	if _, err := r.ValidateVerifiedPair(h); err == nil {
		t.Fatal("renewed proof reopened admission")
	}
	if h.state.membership != m {
		t.Fatal("renewal changed immutable grant")
	}
	for _, member := range p {
		if err := r.ObserveVerifiedPairOwnerReleased(h, member, m.TranscriptSHA256); err != nil {
			t.Fatal("proof-only cleanup renewal refused", err)
		}
	}
	pairTestRequirePhase(t, r, h, VerifiedPairReleased)
}
