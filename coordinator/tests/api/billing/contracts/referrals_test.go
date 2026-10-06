package billing_test

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func referralRequest(t *testing.T, srv *billingFixture, method, path, body, account string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	srv.withUser(req, &store.User{AccountID: account})
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)
	return w
}

func referralResponse(t *testing.T, w *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	if w.Code != http.StatusOK {
		t.Fatalf("status %d: %s", w.Code, w.Body.String())
	}
	var response map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	return response
}

func TestReferralInfoUnregisteredConsumer(t *testing.T) {
	srv, _, _ := billingTestServer(t)
	info := referralResponse(t, referralRequest(t, srv, http.MethodGet, "/v1/referral/info", "", "consumer"))
	if info["code"] != "" || info["referred_by"] != "" || info["share_percent"] != float64(5) || info["reward_basis"] != "consumer_spend" {
		t.Fatalf("unexpected info: %v", info)
	}
	w := referralRequest(t, srv, http.MethodGet, "/v1/referral/stats", "", "consumer")
	if w.Code != http.StatusNotFound {
		t.Fatalf("unregistered stats: %d %s", w.Code, w.Body.String())
	}
}

func TestReferralRoutesRegisterApplyInfo(t *testing.T) {
	srv, _, _ := billingTestServer(t)
	registered := referralResponse(t, referralRequest(t, srv, http.MethodPost, "/v1/referral/register", `{"code":"partner"}`, "partner"))
	if registered["code"] != "PARTNER" || registered["share_percent"] != float64(5) || registered["reward_basis"] != "consumer_spend" {
		t.Fatalf("registration: %v", registered)
	}
	for i := 0; i < 2; i++ {
		response := referralResponse(t, referralRequest(t, srv, http.MethodPost, "/v1/referral/apply", `{"code":" partner "}`, "consumer"))
		if response["code"] != "PARTNER" {
			t.Fatalf("unnormalized response: %v", response)
		}
	}
	info := referralResponse(t, referralRequest(t, srv, http.MethodGet, "/v1/referral/info", "", "consumer"))
	if info["referred_by"] != "PARTNER" {
		t.Fatalf("missing attribution: %v", info)
	}
	stats := referralResponse(t, referralRequest(t, srv, http.MethodGet, "/v1/referral/stats", "", "partner"))
	if stats["total_referred"] != float64(1) || stats["reward_basis"] != "consumer_spend" {
		t.Fatalf("stats: %v", stats)
	}
}

func TestReferralRoutesRejectInvalidInputAndConflictingAttribution(t *testing.T) {
	srv, st, _ := billingTestServer(t)
	for _, code := range []string{"FIRST", "SECOND"} {
		if err := st.CreateReferrer(code, code); err != nil {
			t.Fatal(err)
		}
	}
	if err := st.RecordReferral("FIRST", "consumer"); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct{ action, body string }{
		{"register", `{"code":"bad!"}`},
		{"register", `{"code":"FIRST"}`},
		{"apply", `{"code":"missing"}`},
		{"apply", `{"code":"SECOND"}`},
	} {
		w := referralRequest(t, srv, http.MethodPost, "/v1/referral/"+tc.action, tc.body, "consumer")
		if w.Code != http.StatusBadRequest || errorTypeOf(t, w.Body.Bytes()) != "referral_error" {
			t.Fatalf("%s %s: %d %s", tc.action, tc.body, w.Code, w.Body.String())
		}
	}
	if code, err := st.GetReferrerForAccount("consumer"); err != nil || code != "FIRST" {
		t.Fatalf("attribution changed: %q %v", code, err)
	}
}

func TestBillingMethodsAdvertiseConsumerSpendReferrals(t *testing.T) {
	srv, _, _ := billingTestServer(t)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/v1/billing/methods", nil))
	response := referralResponse(t, w)
	program, ok := response["referral"].(map[string]any)
	if !ok || program["share_percent"] != float64(5) || program["reward_basis"] != "consumer_spend" {
		t.Fatalf("referral program: %v", response)
	}
}

func TestReferralMutationRoutesRejectLinkedAPIKey(t *testing.T) {
	srv, st, _ := billingTestServer(t)
	user := seedUser(t, st, "linked-consumer", "consumer@example.test")
	rawKey, _, err := st.CreateAPIKey(user.AccountID, store.APIKeyCreate{})
	if err != nil {
		t.Fatal(err)
	}
	if err := st.CreateReferrer("partner", "PARTNER"); err != nil {
		t.Fatal(err)
	}
	// Prove the key authenticates and resolves its linked user on a read route.
	req := httptest.NewRequest(http.MethodGet, "/v1/referral/info", nil)
	req.Header.Set("Authorization", "Bearer "+rawKey)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)
	referralResponse(t, w)

	for _, action := range []string{"register", "apply"} {
		t.Run(action, func(t *testing.T) {
			for _, credential := range []struct {
				name, token string
				status      int
			}{{"linked-key", rawKey, http.StatusForbidden}, {"missing", "", http.StatusUnauthorized}} {
				t.Run(credential.name, func(t *testing.T) {
					code := "MYCODE"
					if action == "apply" {
						code = "PARTNER"
					}
					req := httptest.NewRequest(http.MethodPost, "/v1/referral/"+action, strings.NewReader(`{"code":"`+code+`"}`))
					if credential.token != "" {
						req.Header.Set("Authorization", "Bearer "+credential.token)
					}
					w := httptest.NewRecorder()
					srv.Handler().ServeHTTP(w, req)
					if w.Code != credential.status {
						t.Fatalf("status %d, want %d: %s", w.Code, credential.status, w.Body.String())
					}
				})
			}
		})
	}
	if _, err := st.GetReferrerByAccount(user.AccountID); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("rejected request registered a code: %v", err)
	}
	if code, err := st.GetReferrerForAccount(user.AccountID); err != nil || code != "" {
		t.Fatalf("rejected request changed attribution: code=%q err=%v", code, err)
	}
}

type referralUnavailableStore struct{ store.Store }

func (s referralUnavailableStore) GetReferrerByAccount(string) (*store.Referrer, error) {
	return nil, errors.New("private database connection details")
}

func TestReferralReadOutageIsRetryableAndSanitized(t *testing.T) {
	srv, st, ledger := billingTestServer(t)
	srv.SetBilling(billing.NewService(referralUnavailableStore{st}, ledger, srv.logger, billing.Config{}))
	for _, action := range []string{"info", "stats"} {
		w := referralRequest(t, srv, http.MethodGet, "/v1/referral/"+action, "", "consumer")
		if w.Code != http.StatusServiceUnavailable {
			t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
		}
		if strings.Contains(w.Body.String(), "private database") {
			t.Fatal("leaked internal error")
		}
	}
}
