package provider_test

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestPublicVerificationRowsRemainConsistentDuringRegistrationAndGrantChanges(t *testing.T) {
	s, p, _ := newAuthorizationFixture(t)

	lease := p.GetAppAttestServingAuthorization()
	var workers sync.WaitGroup
	workers.Add(1)
	go func() {
		defer workers.Done()
		for i := range 200 {
			s.registry.ClearAppAttestServingAuthorization(p)
			id := fmt.Sprintf("joining-%d", i)
			s.registry.Register(id, nil, &protocol.RegisterMessage{PublicKey: id})
			s.registry.GrantAppAttestServingAuthorization(p, lease)
			s.registry.Disconnect(id)
		}
	}()
	defer workers.Wait()
	states := map[string]bool{"verified": true, "pending": true, "expired": true, "revoked": true, "unsupported": true, "offline": true}
	for range 200 {
		w := httptest.NewRecorder()
		s.Handler().ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/v1/providers/attestation", nil))
		var body struct {
			Providers []struct {
				Verification registry.Verification `json:"verification"`
				Authorized   bool                  `json:"app_attest_authorized"`
				ExpiresAt    int64                 `json:"authorization_expires_at"`
			} `json:"providers"`
		}
		if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
			t.Fatal(err)
		}
		raw := freshStatsBody(t, s)
		var stats struct {
			Providers []struct {
				Verification registry.Verification `json:"verification"`
			} `json:"providers"`
			Counts verificationSnapshotCounts `json:"verification_counts"`
		}
		if err := json.Unmarshal(raw, &stats); err != nil {
			t.Fatal(err)
		}
		var counted verificationSnapshotMethods
		for _, row := range stats.Providers {
			v := row.Verification
			if v.ObservedAt <= 0 || !states[v.AppAttest.State] || !states[v.Legacy.State] {
				t.Fatalf("invalid stats verdict during registry churn: %+v", v)
			}
			counted.Connections++
			if v.AppAttest.State == "verified" {
				counted.AppAttest++
			}
			if v.Legacy.State == "verified" {
				counted.Legacy++
			}
			if v.AppAttest.State == "verified" || v.Legacy.State == "verified" {
				counted.Authorized++
			}
			if v.AppAttest.State == "verified" && v.Legacy.State == "verified" {
				counted.Overlap++
			}
		}
		if stats.Counts.verificationSnapshotMethods != counted {
			t.Fatalf("stats rows and aggregate disagree: %+v vs %+v", stats.Counts, counted)
		}
		for _, row := range body.Providers {
			v := row.Verification
			if v.ObservedAt <= 0 || !states[v.AppAttest.State] || !states[v.Legacy.State] {
				t.Fatalf("invalid verdict: %+v", row)
			}
			if row.Authorized != (v.AppAttest.State == "verified") {
				t.Fatalf("contradictory verdicts: %+v", row)
			}
			if row.Authorized && row.ExpiresAt != v.AppAttest.ExpiresAt {
				t.Fatalf("mismatched deadlines: %+v", row)
			}
			if !row.Authorized && row.ExpiresAt != 0 {
				t.Fatalf("unauthorized lease deadline: %+v", row)
			}
		}
	}
}

// Local response views keep cross-domain contracts independent of the private
// reporting accumulators; expectations count the serialized rows directly.
type verificationSnapshotMethods struct {
	Connections int `json:"connections"`
	Authorized  int `json:"authorized"`
	AppAttest   int `json:"app_attest"`
	Legacy      int `json:"legacy"`
	Overlap     int `json:"overlap"`
}

type verificationSnapshotCounts struct {
	verificationSnapshotMethods
	KnownMachines   int `json:"known_unique_machines"`
	ReportedMacOS27 int `json:"reported_macos_27_or_later"`
	ReportedOS      int `json:"connections_with_reported_os"`
}

func freshStatsBody(t *testing.T, s *authorizationFixture) []byte {
	t.Helper()
	// Cache invalidation and fresh-snapshot aggregation are tested by reporting's owner tests.
	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/v1/stats", nil))
	if w.Code != http.StatusOK {
		t.Fatalf("stats status=%d body=%s", w.Code, w.Body.String())
	}
	return w.Body.Bytes()
}
