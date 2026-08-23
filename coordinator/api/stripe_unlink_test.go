package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// --- Unlink ---

func TestStripeUnlinkClearsAccount(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := readyUser(t, st, "acct-unlink-1", "unlink@example.com", false)

	req := httptest.NewRequest(http.MethodDelete, "/v1/billing/stripe/account", nil)
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeUnlink(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}
	var resp map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	if resp["unlinked"] != true {
		t.Errorf("unlinked = %v, want true", resp["unlinked"])
	}
	refreshed, _ := st.GetUserByAccountID(user.AccountID)
	if refreshed.StripeAccountID != "" {
		t.Errorf("StripeAccountID = %q, want empty", refreshed.StripeAccountID)
	}
	if refreshed.StripeAccountStatus != "" {
		t.Errorf("status = %q, want empty", refreshed.StripeAccountStatus)
	}

	// Second unlink is a no-op.
	refreshed, _ = st.GetUserByAccountID(user.AccountID)
	req2 := httptest.NewRequest(http.MethodDelete, "/v1/billing/stripe/account", nil)
	req2 = withPrivyUser(req2, refreshed)
	w2 := httptest.NewRecorder()
	srv.handleStripeUnlink(w2, req2)
	if w2.Code != http.StatusOK {
		t.Fatalf("second unlink got %d", w2.Code)
	}
	var resp2 map[string]any
	_ = json.Unmarshal(w2.Body.Bytes(), &resp2)
	if resp2["unlinked"] != false {
		t.Errorf("second unlink = %v, want false", resp2["unlinked"])
	}
}

func TestStripeUnlinkRequiresAuth(t *testing.T) {
	srv, _ := stripePayoutsTestServer(t, true, nil)
	req := httptest.NewRequest(http.MethodDelete, "/v1/billing/stripe/account", nil)
	w := httptest.NewRecorder()
	srv.handleStripeUnlink(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("got %d, want 401", w.Code)
	}
}

// TestStripeUnlinkRouteRejectsAPIKey: unlink is account management — it must
// require an interactive Privy session, not be reachable with a (leakable)
// inference API key.
func TestStripeUnlinkRouteRejectsAPIKey(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := readyUser(t, st, "acct-unlink-key", "alice@example.com", false)

	rawKey, _, err := st.CreateAPIKey(user.AccountID, store.APIKeyCreate{})
	if err != nil {
		t.Fatalf("create api key: %v", err)
	}

	req := httptest.NewRequest(http.MethodDelete, "/v1/billing/stripe/account", nil)
	req.Header.Set("Authorization", "Bearer "+rawKey)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusForbidden {
		t.Fatalf("got %d, want 403 (API keys must not unlink payout accounts): %s", w.Code, w.Body.String())
	}
	refreshed, _ := st.GetUserByAccountID(user.AccountID)
	if refreshed.StripeAccountID == "" {
		t.Error("account must still be linked")
	}
}
