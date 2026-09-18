package api

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestOwnerFleetAppAttestAuthorizationIsLiveScopedAndRedacted(t *testing.T) {
	s, p, _ := newAuthorizationFixture(t)
	p.Mu().Lock()
	p.FailedChallenges = 3 // Missed legacy challenges do not cancel this lease.
	p.Mu().Unlock()
	fleet, err := s.mergeFleet(context.Background(), "account")
	if err != nil || len(fleet) != 1 {
		t.Fatalf("fleet=%+v err=%v", fleet, err)
	}
	mp := fleet[0]
	if !myProviderHasAppAttestAuthorization(&mp, time.Now()) || needsAttention(&mp, "0.9.4") {
		t.Fatal("qualified App Attest-only provider was reported as awaiting legacy verification")
	}
	if mp.TrustLevel != "self_signed" || mp.MDAVerified {
		t.Fatal("App Attest fabricated legacy proof fields")
	}
	data, err := json.Marshal(mp)
	if err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{`"machine_id"`, `"credential_id"`, `"key_id"`, `"receipt"`} {
		if strings.Contains(string(data), field) {
			t.Fatalf("owner diagnostic exposed private App Attest field %s", field)
		}
	}
	other, err := s.mergeFleet(context.Background(), "other-account")
	if err != nil || len(other) != 0 {
		t.Fatal("another account received the live provider")
	}
	mp.AuthorizationExpiresAt = time.Now().Unix()
	if !needsAttention(&mp, "0.9.4") {
		t.Fatal("expired diagnostic hid missing authorization")
	}
	s.registry.RevokeAppAttestCredential("credential")
	fleet, err = s.mergeFleet(context.Background(), "account")
	if err != nil || len(fleet) != 1 || fleet[0].AppAttestAuthorized || fleet[0].AuthorizationExpiresAt != 0 {
		t.Fatalf("revoked authorization remained in owner fleet: %+v %v", fleet, err)
	}
	if !needsAttention(&fleet[0], "0.9.4") {
		t.Fatal("revoked provider lost attention warning")
	}
}

func TestOwnerFleetOSVersionUsesLiveReportOrLastStoredReport(t *testing.T) {
	s, p, _ := newAuthorizationFixture(t)
	storedJSON, err := json.Marshal(attestation.VerificationResult{OSVersion: "26.5.2"})
	if err != nil {
		t.Fatal(err)
	}
	record := &store.ProviderRecord{ID: p.ID, AccountID: "account", AttestationResult: storedJSON}
	if offline := buildMyProvider(record, nil); offline.OSVersion != "26.5.2" || offline.AppAttestAuthorized {
		t.Fatalf("stored version should be last-reported metadata only: %+v", offline)
	}
	// Missing current metadata must not make the upgraded machine appear to
	// still run the OS from an earlier connection's stored record.
	if live := buildMyProvider(record, p); live.OSVersion != "" {
		t.Fatalf("missing live version inherited old report: %s", live.OSVersion)
	}
	p.Mu().Lock()
	p.AttestationResult.OSVersion = "27.0.0"
	p.Mu().Unlock()
	if live := buildMyProvider(record, p); live.OSVersion != "27.0.0" {
		t.Fatalf("live version did not replace stored version: %s", live.OSVersion)
	}
	mp := buildMyProvider(nil, p)
	s.attachMyProviderAuthorization(&mp, p, "account")
	if !mp.AppAttestAuthorized {
		t.Fatal("fixture authorization missing")
	}
	s.attachMyProviderAuthorization(&mp, p, "other-account")
	if mp.AppAttestAuthorized || mp.AuthorizationExpiresAt != 0 {
		t.Fatal("authorization reused across account boundary")
	}
}
