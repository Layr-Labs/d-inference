package billing_test

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestCheckoutNormalizesReferralCode(t *testing.T) {
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/v1/checkout/sessions" {
			t.Errorf("unexpected Stripe request: %s %s", r.Method, r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
			return
		}
		if err := r.ParseForm(); err != nil {
			t.Error(err)
		}
		if code := r.Form.Get("metadata[referral_code]"); code != "PARTNER" {
			t.Errorf("Stripe referral metadata = %q", code)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":"cs_referral","url":"https://checkout.example.test/session"}`))
	}))
	defer fakeStripe.Close()
	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	if err := st.CreateReferrer("partner", "PARTNER"); err != nil {
		t.Fatal(err)
	}
	response := referralResponse(t, referralRequest(t, srv, http.MethodPost, "/v1/billing/stripe/create-session", `{"amount_usd":"5.00","referral_code":" partner "}`, "consumer"))
	session, err := st.GetBillingSession(response["session_id"].(string))
	if err != nil {
		t.Fatal(err)
	}
	if session.ReferralCode != "PARTNER" {
		t.Fatalf("stored referral code = %q", session.ReferralCode)
	}
}
