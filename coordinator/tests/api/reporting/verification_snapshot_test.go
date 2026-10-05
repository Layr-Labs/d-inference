package reporting_test

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestVerificationCountsUnionAndDenominators(t *testing.T) {
	s, p := newVerificationFixture(t)

	p.AttestationResult.OSVersion = "27.0.0"
	counts := s.publicVerificationCounts(t)
	if counts.Authorized != 1 || counts.KnownMachines != 1 || counts.ReportedMacOS27 != 1 || counts.ReportedOS != 1 {
		t.Fatalf("public denominators: %+v", counts)
	}
	s.registry.ClearAppAttestServingAuthorization(p)
	counts = s.publicVerificationCounts(t)
	if counts.Authorized != 0 || counts.ReportedMacOS27 != 1 {
		t.Fatal("reported OS was confused with authorization")
	}
	p.PrivateOnly = true
	if counts = s.publicVerificationCounts(t); counts.Connections != 0 || counts.KnownMachines != 0 {
		t.Fatal("private provider entered public counts")
	}
}

// Exercise the reporting handler rather than reaching into its private accumulator.
func (s *reportingFixture) publicVerificationCounts(t *testing.T) verificationSnapshotCounts {
	t.Helper()
	var body struct {
		Counts verificationSnapshotCounts `json:"verification_counts"`
	}
	if err := json.Unmarshal(freshStatsBody(t, s), &body); err != nil {
		t.Fatal(err)
	}
	return body.Counts
}

func TestStatsVerificationRowsRemainConsistentDuringRegistrationAndGrantChanges(t *testing.T) {
	s, p := newVerificationFixture(t)

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

	}
}

func TestStatsAndGeographyUseTheCurrentConnectionVerdict(t *testing.T) {
	s, p := newVerificationFixture(t)

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
	s, p := newVerificationFixture(t)

	p.Mu().Lock()
	p.Location = &store.ProviderLocation{CountryCode: "US", Country: "United States", Region: "California"}
	p.Mu().Unlock()
	deps := s.deps
	deps.Store = &afterFleetWalkStore{Store: s.store, onUsageTotals: func() { deps.Registry.Disconnect(p.ID) }}
	s = newReportingFixture(deps)

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

func freshStatsBody(t *testing.T, s *reportingFixture) []byte {
	t.Helper()
	s.readCache.Invalidate("stats:v1")
	w := httptest.NewRecorder()
	s.HandleStats(w, httptest.NewRequest(http.MethodGet, "/v1/stats", nil))
	if w.Code != http.StatusOK {
		t.Fatalf("stats status=%d body=%s", w.Code, w.Body.String())
	}
	return w.Body.Bytes()
}

func newVerificationProvider(t *testing.T, r *registry.Registry) *registry.Provider {
	t.Helper()
	key := base64.StdEncoding.EncodeToString(make([]byte, 32))
	p := r.Register("connection", nil, &protocol.RegisterMessage{PublicKey: key, AppAttestProtocol: 3, Backend: registry.BackendMLXSwift, EncryptedResponseChunks: true, Hardware: protocol.Hardware{MachineModel: "Mac16,10", MemoryGB: 32}})
	p.AccountID, p.RuntimeVerified, p.RuntimeManifestChecked = "account", true, true
	p.PrivacyCapabilities = &protocol.PrivacyCapabilities{TextBackendInprocess: true, TextProxyDisabled: true, AntiDebugEnabled: true, CoreDumpsDisabled: true, EnvScrubbed: true}
	p.Version, p.MetallibVerified = "0.9.4", true
	p.TemplateHashes = map[string]string{"mlx_metallib": strings.Repeat("b", 64)}
	p.AttestationResult = &attestation.VerificationResult{Valid: true, PublicKey: "se", EncryptionPublicKey: key, MetallibHash: strings.Repeat("b", 64)}
	p.SetAttested(true, registry.TrustSelfSigned)
	p.CompleteProviderStateRestore()
	if !r.BindVerifiedMachineIdentity(p, "account", "machine") {
		t.Fatal("identity")
	}
	r.SetAppAttestServingPolicy(true, 1)
	now := time.Now()
	if !r.GrantAppAttestServingAuthorization(p, registry.AppAttestServingAuthorization{AccountID: "account", MachineID: "machine", CredentialID: "credential", ConnectionID: p.ID, ProofSessionID: "proof", Endpoint: p.PublicKey, PolicyGeneration: 1, IssuedAt: now, ValidUntil: now.Add(30 * time.Second), MachineModel: "Mac16,10", MemoryGB: 32}) {
		t.Fatal("seed registry authorization")
	}
	t.Cleanup(func() { r.Disconnect(p.ID) })
	return p
}
func newVerificationFixture(t *testing.T) (*reportingFixture, *registry.Provider) {
	s := newStatsSnapshotServer(memory.NewMemory(store.Config{}))
	return s, newVerificationProvider(t, s.registry)
}
