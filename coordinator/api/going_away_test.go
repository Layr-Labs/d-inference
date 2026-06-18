package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const goingAwayAdminKey = "going-away-admin-key"

// newGoingAwayServer builds a real Server with the admin key set so the
// admin-gated POST /v1/admin/going-away endpoint can be exercised end-to-end.
func newGoingAwayServer(t *testing.T) (*Server, *store.MemoryStore) {
	t.Helper()
	logger := quietLogger()
	st := store.NewMemory(store.Config{})
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)
	srv.SetAdminKey(goingAwayAdminKey)
	return srv, st
}

// TestHandleGoingAway_AdminKeyReturnsSentCount verifies the discrete planned-
// restart trigger (DAR-327 Phase 3): an admin-keyed POST broadcasts going_away,
// returns 200 with the {"sent": <int>} count, and latches the going-away flag.
func TestHandleGoingAway_AdminKeyReturnsSentCount(t *testing.T) {
	srv, _ := newGoingAwayServer(t)

	if srv.goingAway.Load() {
		t.Fatal("goingAway flag must start false")
	}

	req := httptest.NewRequest(http.MethodPost, "/v1/admin/going-away", nil)
	req.Header.Set("Authorization", "Bearer "+goingAwayAdminKey)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d (body: %s)", w.Code, http.StatusOK, w.Body.String())
	}

	var body map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	// No providers connected, so the broadcast reaches zero.
	sent, ok := body["sent"].(float64)
	if !ok {
		t.Fatalf("response missing numeric \"sent\" field: %v", body)
	}
	if sent != 0 {
		t.Errorf("sent = %v, want 0 (no providers connected)", sent)
	}

	// The endpoint must latch the flag so subsequent registrations are refused.
	if !srv.goingAway.Load() {
		t.Error("goingAway flag must be set after the broadcast")
	}
}

// TestHandleGoingAway_RequiresAdmin verifies the endpoint is admin-gated: a
// request with no credentials is rejected by requireAuth (401), and a valid but
// non-admin API key is rejected by isAdminAuthorized (403). Neither path may
// latch the going-away flag.
func TestHandleGoingAway_RequiresAdmin(t *testing.T) {
	t.Run("missing credentials", func(t *testing.T) {
		srv, _ := newGoingAwayServer(t)

		req := httptest.NewRequest(http.MethodPost, "/v1/admin/going-away", nil)
		w := httptest.NewRecorder()
		srv.Handler().ServeHTTP(w, req)

		if w.Code != http.StatusUnauthorized {
			t.Fatalf("status = %d, want %d", w.Code, http.StatusUnauthorized)
		}
		if srv.goingAway.Load() {
			t.Error("goingAway flag must NOT be set when auth fails")
		}
	})

	t.Run("non-admin api key", func(t *testing.T) {
		srv, st := newGoingAwayServer(t)

		raw, err := st.CreateKey()
		if err != nil {
			t.Fatalf("CreateKey: %v", err)
		}

		req := httptest.NewRequest(http.MethodPost, "/v1/admin/going-away", nil)
		req.Header.Set("Authorization", "Bearer "+raw)
		w := httptest.NewRecorder()
		srv.Handler().ServeHTTP(w, req)

		if w.Code != http.StatusForbidden {
			t.Fatalf("status = %d, want %d (body: %s)", w.Code, http.StatusForbidden, w.Body.String())
		}
		if srv.goingAway.Load() {
			t.Error("goingAway flag must NOT be set for a non-admin caller")
		}
	})
}

// TestBroadcastGoingAway_LatchesFlag verifies the flag is set by the shared
// BroadcastGoingAway path (used by both the admin endpoint and graceful
// shutdown), independent of how many providers it reaches.
func TestBroadcastGoingAway_LatchesFlag(t *testing.T) {
	srv, _ := newGoingAwayServer(t)

	if got := srv.BroadcastGoingAway(); got != 0 {
		t.Errorf("BroadcastGoingAway sent = %d, want 0 (no providers)", got)
	}
	if !srv.goingAway.Load() {
		t.Error("goingAway flag must be set after BroadcastGoingAway")
	}
}

// TestHandleProviderWS_RefusesRegistrationWhenGoingAway verifies finding (C):
// once the coordinator has announced going_away, the provider WebSocket upgrade
// handler refuses NEW registrations with 503 (and a Retry-After) BEFORE the
// upgrade, so a reconnecting provider doesn't stick to this dying instance.
func TestHandleProviderWS_RefusesRegistrationWhenGoingAway(t *testing.T) {
	srv, _ := newGoingAwayServer(t)
	srv.goingAway.Store(true)

	req := httptest.NewRequest(http.MethodGet, "/ws/provider", nil)
	w := httptest.NewRecorder()
	srv.handleProviderWS(w, req)

	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusServiceUnavailable)
	}
	if got := w.Header().Get("Retry-After"); got == "" {
		t.Error("expected a Retry-After header on the 503")
	}
}
