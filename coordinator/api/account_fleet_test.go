package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Drive the registered Privy routes after changing the dependencies they use.
// Provider removal must consult the current fleet and write the current store.
func TestAccountFleetRoutesUseCurrentBindings(t *testing.T) {
	srv, original := newKeyTestServer(t)
	t.Cleanup(srv.Close)
	user := &store.User{AccountID: "fleet-binding-account", PrivyUserID: "did:privy:fleet-binding", StripeAccountStatus: "ready"}
	if err := original.CreateUser(user); err != nil {
		t.Fatal(err)
	}
	session := privySession(t, srv, original, user)
	handler := srv.Handler()
	call := func(method, path string, wantStatus int) []byte {
		t.Helper()
		r := httptest.NewRequest(method, path, nil)
		r.Header.Set("Authorization", "Bearer "+session)
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		if w.Code != wantStatus {
			t.Fatalf("%s %s: %d %s", method, path, w.Code, w.Body.String())
		}
		return w.Body.Bytes()
	}
	seed := func(st *store.MemoryStore, amount int64, version string) {
		t.Helper()
		if err := st.RecordProviderEarning(&store.ProviderEarning{
			AccountID: user.AccountID, ProviderID: "fleet-machine", JobID: "binding-job", AmountMicroUSD: amount,
		}); err != nil {
			t.Fatal(err)
		}
		if err := st.SetRelease(&store.Release{Version: version, Platform: defaultReleasePlatform, Active: true}); err != nil {
			t.Fatal(err)
		}
	}
	readSummary := func(wantMoney int64, wantLatest, wantMinimum string, wantTotal, wantAttention int) {
		t.Helper()
		var body struct {
			AccountID     string `json:"account_id"`
			PayoutReady   bool   `json:"payout_ready"`
			LifetimeMoney int64  `json:"lifetime_micro_usd"`
			Latest        string `json:"latest_provider_version"`
			Minimum       string `json:"min_provider_version"`
			Counts        struct {
				Total     int `json:"total"`
				Attention int `json:"needs_attention"`
			} `json:"counts"`
		}
		if err := json.Unmarshal(call(http.MethodGet, "/v1/me/summary", http.StatusOK), &body); err != nil {
			t.Fatal(err)
		}
		if body.AccountID != user.AccountID || !body.PayoutReady || body.LifetimeMoney != wantMoney || body.Latest != wantLatest || body.Minimum != wantMinimum || body.Counts.Total != wantTotal || body.Counts.Attention != wantAttention {
			t.Fatalf("summary retained an old dependency or lost the authenticated user: %+v", body)
		}
	}
	seed(original, 111, "1.1.0")
	srv.SetMinProviderVersion("1.0.0")
	readSummary(111, "1.1.0", "1.0.0", 0, 0)

	replacement := store.NewMemory(store.Config{})
	seed(replacement, 222, "2.2.0")
	srv.store = replacement
	srv.readCache = newTTLCache()
	readSummary(222, "2.2.0", "1.0.0", 0, 0)

	fleet := registry.New(srv.logger)
	p := fleet.Register("fleet-machine", nil, &protocol.RegisterMessage{Version: "1.5.0"})
	p.Mu().Lock()
	p.AccountID = user.AccountID
	p.Version = "1.5.0"
	p.Status = registry.StatusOnline
	p.TrustLevel = registry.TrustHardware
	p.Attested = true
	p.RuntimeVerified = true
	p.Mu().Unlock()
	srv.registry = fleet
	readSummary(222, "2.2.0", "1.0.0", 1, 0)
	srv.SetMinProviderVersion("2.0.0")
	readSummary(222, "2.2.0", "2.0.0", 1, 1)
	var providers struct {
		Providers []struct {
			ID string `json:"id"`
		} `json:"providers"`
	}
	if err := json.Unmarshal(call(http.MethodGet, "/v1/me/providers", http.StatusOK), &providers); err != nil {
		t.Fatal(err)
	}
	if len(providers.Providers) != 1 || providers.Providers[0].ID != p.ID {
		t.Fatalf("provider route retained its previous fleet: %+v", providers)
	}

	windows := store.AccountEarningsWindows{Last24hMicroUSD: 777, Last7dMicroUSD: 888}
	cached, err := json.Marshal(windows)
	if err != nil {
		t.Fatal(err)
	}
	srv.readCache.Set("me:summary:windows:"+user.AccountID, cached, time.Minute)
	var summary struct {
		Last24h int64 `json:"last_24h_micro_usd"`
		Last7d  int64 `json:"last_7d_micro_usd"`
	}
	if err := json.Unmarshal(call(http.MethodGet, "/v1/me/summary", http.StatusOK), &summary); err != nil {
		t.Fatal(err)
	}
	if summary.Last24h != 777 || summary.Last7d != 888 {
		t.Fatalf("summary did not use the current shared cache: %+v", summary)
	}

	if err := replacement.UpsertProvider(context.Background(), store.ProviderRecord{ID: p.ID, AccountID: user.AccountID}); err != nil {
		t.Fatal(err)
	}
	call(http.MethodDelete, "/v1/me/providers/"+p.ID, http.StatusConflict)
	srv.registry = registry.New(srv.logger)
	call(http.MethodDelete, "/v1/me/providers/"+p.ID, http.StatusOK)
	if records, err := replacement.ListProvidersByAccount(context.Background(), user.AccountID); err != nil || len(records) != 0 {
		t.Fatalf("offline provider remained in the current store: records=%+v err=%v", records, err)
	}
}
