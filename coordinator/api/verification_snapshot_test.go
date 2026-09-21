package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestPublicVerificationRowsRemainConsistentDuringRegistrationAndGrantChanges(t *testing.T) {
	s, p, _ := newAuthorizationFixture(t)
	s.readCache = newTTLCache()
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
		s.handleProviderAttestation(w, httptest.NewRequest(http.MethodGet, "/v1/providers/attestation", nil))
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
		raw, err := s.computeStats()
		if err != nil {
			t.Fatal(err)
		}
		var stats struct {
			Providers []struct {
				Verification registry.Verification `json:"verification"`
			} `json:"providers"`
			Counts verificationCounts `json:"verification_counts"`
		}
		if err := json.Unmarshal(raw, &stats); err != nil {
			t.Fatal(err)
		}
		var counted verificationMethodCounts
		for _, row := range stats.Providers {
			v := row.Verification
			if v.ObservedAt <= 0 || !states[v.AppAttest.State] || !states[v.Legacy.State] {
				t.Fatalf("invalid stats verdict during registry churn: %+v", v)
			}
			counted.add(v)
		}
		if stats.Counts.verificationMethodCounts != counted {
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

func TestStatsAndGeographyUseTheCurrentConnectionVerdict(t *testing.T) {
	s, p, _ := newAuthorizationFixture(t)
	s.readCache = newTTLCache()
	p.Mu().Lock()
	p.Location = &store.ProviderLocation{CountryCode: "US", Country: "United States", Region: "California"}
	p.Mu().Unlock()
	assertSnapshot := func(authorized bool) {
		t.Helper()
		raw, err := s.computeStats()
		if err != nil {
			t.Fatal(err)
		}
		var result struct {
			Providers []struct {
				Verification registry.Verification `json:"verification"`
			} `json:"providers"`
			Counts  verificationCounts             `json:"verification_counts"`
			Regions []publicProviderLocationBucket `json:"provider_regions"`
		}
		if err := json.Unmarshal(raw, &result); err != nil {
			t.Fatal(err)
		}
		if len(result.Providers) != 1 || result.Providers[0].Verification.ObservedAt == 0 {
			t.Fatalf("missing snapshot: %s", raw)
		}
		if (result.Providers[0].Verification.AppAttest.State == "verified") != authorized {
			t.Fatalf("stale row: %s", raw)
		}
		want := 0
		if authorized {
			want = 1
		}
		if result.Counts.Authorized != want || len(result.Regions) != 1 || result.Regions[0].Verification.Authorized != want {
			t.Fatalf("inconsistent aggregate: %s", raw)
		}
	}
	assertSnapshot(true)
	s.registry.Disconnect(p.ID)
	replacement := s.registry.Register(p.ID, nil, &protocol.RegisterMessage{PublicKey: "replacement"})
	replacement.Mu().Lock()
	replacement.Location = &store.ProviderLocation{CountryCode: "US", Country: "United States", Region: "California"}
	replacement.Mu().Unlock()
	assertSnapshot(false)
}
