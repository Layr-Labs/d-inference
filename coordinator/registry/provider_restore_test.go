package registry

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestRestoreProviderStateKeepsFreshChallengeVerification(t *testing.T) {
	reg := New(testLogger())
	p := reg.Register("p1", nil, testRegisterMessage())
	fresh := time.Now()
	stale := fresh.Add(-10 * time.Minute)
	p.SetLastChallengeVerified(fresh)
	if err := reg.RestoreProviderState(p, &store.ProviderRecord{
		ID:                    "persisted-p1",
		TrustLevel:            string(TrustHardware),
		Attested:              true,
		LastChallengeVerified: &stale,
	}); err != nil {
		t.Fatal(err)
	}

	if !p.LastChallengeVerified.Equal(fresh) {
		t.Fatalf("LastChallengeVerified = %v, want fresh registration value %v", p.LastChallengeVerified, fresh)
	}
}

func TestRestoreProviderStateAcceptsNewerChallengeVerification(t *testing.T) {
	reg := New(testLogger())
	p := reg.Register("p1", nil, testRegisterMessage())
	old := time.Now().Add(-10 * time.Minute)
	newer := old.Add(5 * time.Minute)
	p.SetLastChallengeVerified(old)
	if err := reg.RestoreProviderState(p, &store.ProviderRecord{
		ID:                    "persisted-p1",
		TrustLevel:            string(TrustSelfSigned),
		Attested:              true,
		LastChallengeVerified: &newer,
	}); err != nil {
		t.Fatal(err)
	}

	if !p.LastChallengeVerified.Equal(newer) {
		t.Fatalf("LastChallengeVerified = %v, want newer stored value %v", p.LastChallengeVerified, newer)
	}
}

// TestRestoreProviderStateDoesNotResurrectMDAWhenSelfSigned is the drift fix:
// a stored record with hardware trust + MDAVerified=true must NOT
// resurrect those proof badges onto a fresh connection. RestoreProviderState
// caps restored trust to self_signed (hardware must be re-earned live), and when
// the live trust is below hardware the MDA flag is forced false — it is
// only meaningful for the connection that earned hardware live. This is what
// kills the misleading "mda_verified=true while self_signed" state on
// /v1/providers/attestation.
func TestRestoreProviderStateDoesNotResurrectMDAWhenSelfSigned(t *testing.T) {
	reg := New(testLogger())
	p := reg.Register("p1", nil, testRegisterMessage())

	rec := &store.ProviderRecord{
		ID:          "p1",
		TrustLevel:  string(TrustHardware), // stored as hardware...
		Attested:    true,
		MDAVerified: true,
	}
	if err := reg.RestoreProviderState(p, rec); err != nil {
		t.Fatal(err)
	}

	// Trust is capped to self_signed (hardware is never resurrected from store).
	if p.GetTrustLevel() != TrustSelfSigned {
		t.Errorf("trust = %q, want %q (restore caps hardware → self_signed)", p.GetTrustLevel(), TrustSelfSigned)
	}
	// The drift fix: the MDA proof must be cleared, not carried over.
	p.Mu().Lock()
	mda := p.MDAVerified
	p.Mu().Unlock()
	if mda {
		t.Error("MDAVerified must be false on a self_signed reconnect (drift guard)")
	}
}

// TestRestoreProviderStateClearsProofsForSelfSignedRecord verifies the
// complementary branch: a record whose stored trust is at/below self_signed is
// restored verbatim (not capped), and the MDA proof is still forced false.
// RestoreProviderState always clears the proof flags (a restored connection is
// always <= self_signed since hardware is capped away), so the guarantee is that
// a restore never produces an MDA proof on a non-hardware connection — it is
// re-earned live by the MDA leg this connection.
func TestRestoreProviderStateClearsProofsForSelfSignedRecord(t *testing.T) {
	reg := New(testLogger())
	p := reg.Register("p1", nil, testRegisterMessage())

	rec := &store.ProviderRecord{
		ID:          "p1",
		TrustLevel:  string(TrustSelfSigned),
		MDAVerified: true,
	}
	if err := reg.RestoreProviderState(p, rec); err != nil {
		t.Fatal(err)
	}

	if p.GetTrustLevel() != TrustSelfSigned {
		t.Errorf("trust = %q, want %q", p.GetTrustLevel(), TrustSelfSigned)
	}
	p.Mu().Lock()
	mda := p.MDAVerified
	p.Mu().Unlock()
	if mda {
		t.Errorf("MDA proof must be false for a non-hardware restore, got mda=%v", mda)
	}
}
