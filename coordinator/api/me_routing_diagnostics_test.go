package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// GET /v1/me/providers must tell an owner why a machine is not advertising.
// Before this existed the response carried a dozen green booleans and no
// verdict, so a fenced node looked identical to a healthy one — the
// "trust=hardware, challenges passing, model warm, doctor 30 PASS / 0 FAIL,
// still serving nothing" report.
//
// These assert on the DECODED WIRE JSON, not the Go struct, so the field names
// the console UI and `darkbloom doctor` key off are pinned.

type wireModelRouting struct {
	ID             string   `json:"id"`
	PubliclyListed bool     `json:"publicly_listed"`
	OwnerRoutable  bool     `json:"owner_routable"`
	Blockers       []string `json:"blockers"`
}

type wireRouting struct {
	Advertising            bool               `json:"advertising"`
	Routable               bool               `json:"routable"`
	OwnerRoutable          bool               `json:"owner_routable"`
	Blockers               []string           `json:"blockers"`
	Models                 []wireModelRouting `json:"models"`
	ChallengeMaxAgeSeconds int                `json:"challenge_max_age_seconds"`
}

type wireProvider struct {
	ID              string       `json:"id"`
	Status          string       `json:"status"`
	RuntimeVerified bool         `json:"runtime_verified"`
	Routing         *wireRouting `json:"routing"`
}

type wireProvidersResponse struct {
	Providers []wireProvider `json:"providers"`
}

const routingTestModel = "gemma-4-26b-qat-4bit"

// registerRoutableProvider puts a fully-healthy live provider in the registry.
func registerRoutableProvider(t *testing.T, srv *Server, id, accountID string) *registry.Provider {
	t.Helper()
	p := srv.registry.Register(id, nil, &protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{MachineModel: "Mac15,8", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: routingTestModel, ModelType: "chat"}},
		Backend:                 registry.BackendMLXSwift,
		PublicKey:               "fX6XYH7p2hmM3ogeXaAsY+p8M6UKD1df/LJUN9Nj9Nw=",
		EncryptedResponseChunks: true,
		PrivacyCapabilities: &protocol.PrivacyCapabilities{
			TextBackendInprocess: true,
			TextProxyDisabled:    true,
			AntiDebugEnabled:     true,
			CoreDumpsDisabled:    true,
			EnvScrubbed:          true,
		},
	})
	p.Mu().Lock()
	p.AccountID = accountID
	p.TrustLevel = registry.TrustHardware
	p.RuntimeVerified = true
	p.RuntimeManifestChecked = true
	p.ChallengeVerifiedSIP = true
	p.LastChallengeVerified = time.Now()
	p.Mu().Unlock()
	return p
}

func fetchMyProviders(t *testing.T, srv *Server, accountID string) wireProvidersResponse {
	t.Helper()
	w := httptest.NewRecorder()
	srv.handleMyProviders(w, reqWithUser(http.MethodGet, "/v1/me/providers", "", accountID))
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", w.Code, w.Body.String())
	}
	var resp wireProvidersResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal: %v\nbody: %s", err, w.Body.String())
	}
	return resp
}

func TestMyProviders_HealthyMachineReportsAdvertising(t *testing.T) {
	srv, _ := newKeyTestServer(t)
	srv.registry.MinTrustLevel = registry.TrustHardware
	registerRoutableProvider(t, srv, "p1", "acct-1")

	resp := fetchMyProviders(t, srv, "acct-1")
	if len(resp.Providers) != 1 {
		t.Fatalf("providers = %d, want 1", len(resp.Providers))
	}
	routing := resp.Providers[0].Routing
	if routing == nil {
		t.Fatal("response carries no routing verdict")
	}
	if !routing.Advertising || !routing.Routable || !routing.OwnerRoutable {
		t.Fatalf("healthy machine reported %+v", routing)
	}
	if len(routing.Blockers) != 0 {
		t.Fatalf("healthy machine reported blockers %v", routing.Blockers)
	}
	if routing.ChallengeMaxAgeSeconds != int(registry.ChallengeFreshnessMaxAge.Seconds()) {
		t.Fatalf("challenge_max_age_seconds = %d, want %d",
			routing.ChallengeMaxAgeSeconds, int(registry.ChallengeFreshnessMaxAge.Seconds()))
	}
	if len(routing.Models) != 1 || !routing.Models[0].PubliclyListed {
		t.Fatalf("model rows = %+v", routing.Models)
	}
}

// The reported shape: every legacy field green, nothing served.
func TestMyProviders_GreenDashboardButFencedExplainsWhy(t *testing.T) {
	cases := []struct {
		name    string
		break_  func(p *registry.Provider)
		blocker string
	}{
		{"stale challenge", func(p *registry.Provider) {
			p.LastChallengeVerified = time.Now().Add(-registry.ChallengeFreshnessMaxAge - time.Minute)
		}, "attestation_challenge_stale"},
		{"sip unverified", func(p *registry.Provider) { p.ChallengeVerifiedSIP = false }, "sip_unverified"},
		{"manifest unchecked", func(p *registry.Provider) { p.RuntimeManifestChecked = false }, "runtime_manifest_unchecked"},
		{"runtime mismatch", func(p *registry.Provider) { p.RuntimeVerified = false }, "runtime_hash_mismatch"},
		{"no models", func(p *registry.Provider) { p.Models = nil }, "no_models_registered"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			srv, _ := newKeyTestServer(t)
			srv.registry.MinTrustLevel = registry.TrustHardware
			p := registerRoutableProvider(t, srv, "p1", "acct-1")
			p.Mu().Lock()
			tc.break_(p)
			p.Mu().Unlock()

			routing := fetchMyProviders(t, srv, "acct-1").Providers[0].Routing
			if routing == nil {
				t.Fatal("response carries no routing verdict")
			}
			// `routable`, not `advertising`: the public catalog deliberately
			// omits the runtime-hash and challenge-freshness gates, so a fenced
			// machine can still be counted there.
			if routing.Routable {
				t.Fatalf("fenced machine reported as routable: %+v", routing)
			}
			found := false
			for _, b := range routing.Blockers {
				if b == tc.blocker {
					found = true
				}
			}
			if !found {
				t.Fatalf("blockers = %v, want to contain %q", routing.Blockers, tc.blocker)
			}
		})
	}
}

// A stale-hash catalog build is dropped per MODEL, so the machine-level
// verdict has to point at the model rows rather than claim the machine is fine.
func TestMyProviders_PerModelBlockersAreReported(t *testing.T) {
	srv, _ := newKeyTestServer(t)
	srv.registry.MinTrustLevel = registry.TrustHardware
	p := registerRoutableProvider(t, srv, "p1", "acct-1")
	p.Mu().Lock()
	p.Models = []protocol.ModelInfo{{ID: routingTestModel, WeightHash: "stale"}}
	p.Mu().Unlock()
	srv.registry.SetModelCatalog([]registry.CatalogEntry{
		{ID: routingTestModel, WeightHash: "expected"},
	})

	routing := fetchMyProviders(t, srv, "acct-1").Providers[0].Routing
	if routing.Advertising || routing.Routable {
		t.Fatalf("machine with only a stale-hash build must not advertise: %+v", routing)
	}
	if len(routing.Blockers) != 1 || routing.Blockers[0] != "no_routable_models" {
		t.Fatalf("machine blockers = %v, want [no_routable_models]", routing.Blockers)
	}
	if len(routing.Models) != 1 {
		t.Fatalf("model rows = %+v", routing.Models)
	}
	m := routing.Models[0]
	if m.PubliclyListed || len(m.Blockers) != 1 || m.Blockers[0] != "model_weight_hash_mismatch" {
		t.Fatalf("model row = %+v", m)
	}
}

// An offline machine must not read as "no problems" just because there is no
// live provider to interrogate.
func TestMyProviders_OfflineMachineReportsOffline(t *testing.T) {
	srv, st := newKeyTestServer(t)
	seedProviderRecord(t, st, "p-old", "SER-OLD", "acct-1")

	resp := fetchMyProviders(t, srv, "acct-1")
	if len(resp.Providers) != 1 {
		t.Fatalf("providers = %d, want 1", len(resp.Providers))
	}
	routing := resp.Providers[0].Routing
	if routing == nil {
		t.Fatal("offline machine carries no routing verdict")
	}
	if routing.Advertising || routing.Routable {
		t.Fatal("offline machine reported as advertising")
	}
	if len(routing.Blockers) != 1 || routing.Blockers[0] != "offline" {
		t.Fatalf("blockers = %v, want [offline]", routing.Blockers)
	}
}
