package registry

import (
	"testing"
)

// TestCodeAttestationCoverage verifies the operator-facing coverage counter used
// to judge when it is safe to let APNS_ENFORCE_AFTER pass.
func TestCodeAttestationCoverage(t *testing.T) {
	r := New(testLogger())
	insertTestProvider(r, &Provider{ID: "a", Status: StatusOnline, CodeAttested: true})
	insertTestProvider(r, &Provider{ID: "b", Status: StatusOnline, CodeAttested: false})
	insertTestProvider(r, &Provider{ID: "c", Status: StatusUntrusted, CodeAttested: true}) // excluded
	insertTestProvider(r, &Provider{ID: "d", Status: StatusOffline, CodeAttested: true})   // excluded

	attested, online := r.CodeAttestationCoverage()
	if online != 2 {
		t.Fatalf("expected 2 online (non-offline/untrusted), got %d", online)
	}
	if attested != 1 {
		t.Fatalf("expected 1 code-attested online provider, got %d", attested)
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
