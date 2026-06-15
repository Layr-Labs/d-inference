package registry

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// TestRestoreProviderStateDoesNotResurrectMDAWhenSelfSigned is the drift fix:
// a stored record with hardware trust + MDAVerified/ACMEVerified=true must NOT
// resurrect those proof badges onto a fresh connection. RestoreProviderState
// caps restored trust to self_signed (hardware must be re-earned live), and when
// the live trust is below hardware the MDA/ACME flags are forced false — they
// are only meaningful for the connection that earned hardware live. This is what
// kills the misleading "mda_verified=true while self_signed" state on
// /v1/providers/attestation.
func TestRestoreProviderStateDoesNotResurrectMDAWhenSelfSigned(t *testing.T) {
	reg := New(testLogger())
	p := reg.Register("p1", nil, testRegisterMessage())

	rec := &store.ProviderRecord{
		ID:           "p1",
		TrustLevel:   string(TrustHardware), // stored as hardware...
		Attested:     true,
		MDAVerified:  true,
		ACMEVerified: true,
	}

	reg.RestoreProviderState(p, rec)

	// Trust is capped to self_signed (hardware is never resurrected from store).
	if p.GetTrustLevel() != TrustSelfSigned {
		t.Errorf("trust = %q, want %q (restore caps hardware → self_signed)", p.GetTrustLevel(), TrustSelfSigned)
	}
	// The drift fix: MDA/ACME proofs must be cleared, not carried over.
	p.Mu().Lock()
	mda, acme := p.MDAVerified, p.ACMEVerified
	p.Mu().Unlock()
	if mda {
		t.Error("MDAVerified must be false on a self_signed reconnect (drift guard)")
	}
	if acme {
		t.Error("ACMEVerified must be false on a self_signed reconnect (drift guard)")
	}
}

// TestRestoreProviderStateClearsProofsForSelfSignedRecord verifies the
// complementary branch: a record whose stored trust is at/below self_signed is
// restored verbatim (not capped), and MDA/ACME proofs are still forced false.
// RestoreProviderState always clears the proof flags (a restored connection is
// always <= self_signed since hardware is capped away), so the guarantee is that
// a restore never produces MDA/ACME proofs on a non-hardware connection — they
// are re-earned live by the MDM/ACME legs this connection.
func TestRestoreProviderStateClearsProofsForSelfSignedRecord(t *testing.T) {
	reg := New(testLogger())
	p := reg.Register("p1", nil, testRegisterMessage())

	rec := &store.ProviderRecord{
		ID:           "p1",
		TrustLevel:   string(TrustSelfSigned),
		MDAVerified:  true,
		ACMEVerified: true,
	}
	reg.RestoreProviderState(p, rec)

	if p.GetTrustLevel() != TrustSelfSigned {
		t.Errorf("trust = %q, want %q", p.GetTrustLevel(), TrustSelfSigned)
	}
	p.Mu().Lock()
	mda, acme := p.MDAVerified, p.ACMEVerified
	p.Mu().Unlock()
	if mda || acme {
		t.Errorf("proofs must be false for a non-hardware restore, got mda=%v acme=%v", mda, acme)
	}
}

// TestProviderCountByTrustStatus buckets connected providers by (trust, status),
// excluding offline providers (they are not a live routability problem) while
// including untrusted (the cohort we want visibility into).
func TestProviderCountByTrustStatus(t *testing.T) {
	reg := New(testLogger())

	// Two self_signed online, one hardware online, one untrusted, one offline.
	mk := func(id string, trust TrustLevel, status ProviderStatus) {
		p := reg.Register(id, nil, testRegisterMessage())
		p.Mu().Lock()
		p.TrustLevel = trust
		p.Status = status
		p.Mu().Unlock()
	}
	mk("ss1", TrustSelfSigned, StatusOnline)
	mk("ss2", TrustSelfSigned, StatusOnline)
	mk("hw1", TrustHardware, StatusOnline)
	mk("un1", TrustSelfSigned, StatusUntrusted)
	mk("off1", TrustHardware, StatusOffline) // excluded

	counts := reg.ProviderCountByTrustStatus()

	get := func(trust, status string) int {
		for _, c := range counts {
			if c.TrustLevel == trust && c.Status == status {
				return c.Count
			}
		}
		return 0
	}

	if n := get(string(TrustSelfSigned), string(StatusOnline)); n != 2 {
		t.Errorf("self_signed/online = %d, want 2", n)
	}
	if n := get(string(TrustHardware), string(StatusOnline)); n != 1 {
		t.Errorf("hardware/online = %d, want 1", n)
	}
	if n := get(string(TrustSelfSigned), string(StatusUntrusted)); n != 1 {
		t.Errorf("self_signed/untrusted = %d, want 1", n)
	}
	// Offline must be excluded entirely.
	for _, c := range counts {
		if c.Status == string(StatusOffline) {
			t.Errorf("offline provider must be excluded, found bucket %+v", c)
		}
	}
	// Total counted = 4 (5 registered minus the offline one).
	total := 0
	for _, c := range counts {
		total += c.Count
	}
	if total != 4 {
		t.Errorf("total counted = %d, want 4 (offline excluded)", total)
	}
}

// TestProviderCountByMDMFailure buckets connected, non-hardware providers by
// MDMFailureReason. Hardware providers are excluded (reason cleared), offline
// excluded, and an empty reason maps to "pending".
func TestProviderCountByMDMFailure(t *testing.T) {
	reg := New(testLogger())

	mk := func(id string, trust TrustLevel, status ProviderStatus, reason string) {
		p := reg.Register(id, nil, testRegisterMessage())
		p.Mu().Lock()
		p.TrustLevel = trust
		p.Status = status
		p.MDMFailureReason = reason
		p.Mu().Unlock()
	}
	mk("a", TrustSelfSigned, StatusOnline, "securityinfo-timeout")
	mk("b", TrustSelfSigned, StatusOnline, "securityinfo-timeout")
	mk("c", TrustSelfSigned, StatusOnline, "device-not-found")
	mk("d", TrustSelfSigned, StatusOnline, "")                  // → pending
	mk("e", TrustHardware, StatusOnline, "")                    // excluded (hardware)
	mk("f", TrustSelfSigned, StatusOffline, "device-not-found") // excluded (offline)

	counts := reg.ProviderCountByMDMFailure()

	if counts["securityinfo-timeout"] != 2 {
		t.Errorf("securityinfo-timeout = %d, want 2", counts["securityinfo-timeout"])
	}
	if counts["device-not-found"] != 1 {
		t.Errorf("device-not-found = %d, want 1 (offline one excluded)", counts["device-not-found"])
	}
	if counts["pending"] != 1 {
		t.Errorf("pending = %d, want 1 (empty reason buckets as pending)", counts["pending"])
	}
	// Hardware provider must not contribute any bucket.
	total := 0
	for _, n := range counts {
		total += n
	}
	if total != 4 {
		t.Errorf("total buckets = %d, want 4 (hardware + offline excluded)", total)
	}
}

// TestSetMDAProofIfHardware covers the atomic late-MDA attach that fixes the
// TOCTOU + data race in the onMDA callback: MDA proof is attached only to a
// connection currently holding hardware trust, with a matching serial, and the
// trust check + writes happen under a single lock.
func TestSetMDAProofIfHardware(t *testing.T) {
	chain := [][]byte{[]byte("der")}
	mda := &attestation.MDAResult{DeviceSerial: "S1", DeviceUDID: "U1"}

	// hardware + matching serial → attaches.
	hw := New(testLogger()).Register("hw", nil, testRegisterMessage())
	hw.Mu().Lock()
	hw.TrustLevel = TrustHardware
	hw.AttestationResult = &attestation.VerificationResult{SerialNumber: "S1"}
	hw.Mu().Unlock()
	if !hw.SetMDAProofIfHardware(chain, mda) {
		t.Fatal("expected attach on hardware provider with matching serial")
	}
	if !hw.MDAVerified || len(hw.MDACertChain) != 1 || hw.MDAResult == nil {
		t.Error("hardware provider should have MDA proof set")
	}

	// self_signed → must NOT attach (this is the drift/TOCTOU guard).
	ss := New(testLogger()).Register("ss", nil, testRegisterMessage())
	ss.Mu().Lock()
	ss.TrustLevel = TrustSelfSigned
	ss.AttestationResult = &attestation.VerificationResult{SerialNumber: "S1"}
	ss.Mu().Unlock()
	if ss.SetMDAProofIfHardware(chain, mda) {
		t.Error("must NOT attach MDA proof to a self_signed provider")
	}
	if ss.MDAVerified {
		t.Error("self_signed provider must not have MDAVerified set")
	}

	// hardware but serial mismatch → must NOT attach (different device).
	mm := New(testLogger()).Register("mm", nil, testRegisterMessage())
	mm.Mu().Lock()
	mm.TrustLevel = TrustHardware
	mm.AttestationResult = &attestation.VerificationResult{SerialNumber: "OTHER"}
	mm.Mu().Unlock()
	if mm.SetMDAProofIfHardware(chain, mda) {
		t.Error("must NOT attach MDA proof when the MDA serial does not match")
	}
}
