package billing

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestStripeStatusReportsCurrentState(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := seedUser(t, st, "acct-status-1", "alice@example.com")
	_ = st.SetUserStripeAccount(user.AccountID, "acct_x", "ready", "", "card", "4242", true)
	user, _ = st.GetUserByAccountID(user.AccountID)

	req := httptest.NewRequest(http.MethodGet, "/v1/billing/stripe/status", nil)
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.StripeStatus(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}
	var resp map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	if resp["status"] != "ready" {
		t.Errorf("status = %v", resp["status"])
	}
	if resp["destination_type"] != "card" {
		t.Errorf("destination_type = %v", resp["destination_type"])
	}
	if resp["destination_last4"] != "4242" {
		t.Errorf("destination_last4 = %v", resp["destination_last4"])
	}
	if resp["instant_eligible"] != true {
		t.Errorf("instant_eligible = %v", resp["instant_eligible"])
	}
}
