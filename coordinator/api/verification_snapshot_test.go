package api

import (
	"encoding/json"
	"fmt"
	"github.com/eigeninference/d-inference/coordinator/api/readcache"
	"github.com/eigeninference/d-inference/coordinator/api/reporting"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
)

func TestPublicVerificationRowsRemainConsistentDuringRegistrationAndGrantChanges(t *testing.T) {
	s, p, _ := newAuthorizationFixture(t)
	s.readCache = readcache.New()
	s.reporting = reporting.New(reporting.Dependencies{Store: s.store, Registry: s.registry, Cache: s.readCache, Logger: s.logger})
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
		s.trust.HandleProviderAttestation(w, httptest.NewRequest(http.MethodGet, "/v1/providers/attestation", nil))
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

func TestStatsAndGeographyUseTheCurrentConnectionVerdict(t *testing.T) {
	s, p, _ := newAuthorizationFixture(t)
	s.readCache = readcache.New()
	s.reporting = reporting.New(reporting.Dependencies{Store: s.store, Registry: s.registry, Cache: s.readCache, Logger: s.logger})
	p.Mu().Lock()
	p.Location = &store.ProviderLocation{CountryCode: "US", Country: "United States", Region: "California"}
	p.Mu().Unlock()
	assertSnapshot := func(authorized bool) {
		t.Helper()
		raw := freshStatsBody(t, s)
		var result struct {
			Providers []struct {
				Verification registry.Verification `json:"verification"`
			} `json:"providers"`
			Counts  verificationSnapshotCounts `json:"verification_counts"`
			Regions []verificationLocationView `json:"provider_regions"`
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

type afterFleetWalkStore struct {
	store.Store
	onUsageTotals func()
	once          sync.Once
}

func (s *afterFleetWalkStore) UsageTotals() (store.UsageTotals, error) {
	s.once.Do(s.onUsageTotals)
	return s.Store.UsageTotals()
}

func TestStatsGeographyUsesTheSameFleetWalkAsProviderRows(t *testing.T) {
	s, p, _ := newAuthorizationFixture(t)
	s.readCache = readcache.New()
	p.Mu().Lock()
	p.Location = &store.ProviderLocation{CountryCode: "US", Country: "United States", Region: "California"}
	p.Mu().Unlock()
	s.store = &afterFleetWalkStore{Store: s.store, onUsageTotals: func() { s.registry.Disconnect(p.ID) }}
	s.reporting = reporting.New(reporting.Dependencies{Store: s.store, Registry: s.registry, Cache: s.readCache, Logger: s.logger})
	raw := freshStatsBody(t, s)
	var snapshot struct {
		Providers []struct {
			Verification registry.Verification `json:"verification"`
		} `json:"providers"`
		Counts  verificationSnapshotCounts `json:"verification_counts"`
		Regions []verificationLocationView `json:"provider_regions"`
	}
	if err := json.Unmarshal(raw, &snapshot); err != nil {
		t.Fatal(err)
	}
	if len(snapshot.Providers) != 1 || snapshot.Counts.Connections != 1 || len(snapshot.Regions) != 1 ||
		snapshot.Regions[0].Providers != 1 || snapshot.Regions[0].Verification.Authorized != snapshot.Counts.Authorized {
		t.Fatalf("geography changed after fleet walk: %s", raw)
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

type verificationLocationView struct {
	Providers    int                         `json:"providers"`
	Verification verificationSnapshotMethods `json:"verification_counts"`
}

func freshStatsBody(t *testing.T, s *Server) []byte {
	t.Helper()
	s.readCache.Invalidate("stats:v1")
	w := httptest.NewRecorder()
	s.reporting.HandleStats(w, httptest.NewRequest(http.MethodGet, "/v1/stats", nil))
	if w.Code != http.StatusOK {
		t.Fatalf("stats status=%d body=%s", w.Code, w.Body.String())
	}
	return w.Body.Bytes()
}
