package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/requestcontext"
	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/payments/baserewards"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Routes are registered before configuration. These real HTTP requests retain
// the published handler while replacing the services it must observe.
func TestBillingControllerUsesCurrentServices(t *testing.T) {
	srv, st := testServerWithConfig(t, ServerConfig{AdminKey: "billing-admin"})
	t.Cleanup(srv.Close)
	server := httptest.NewServer(srv.Handler())
	t.Cleanup(server.Close)
	client := server.Client()
	client.Timeout = 5 * time.Second
	read := func(path, token string, wantStatus int) map[string]any {
		t.Helper()
		req, err := http.NewRequest(http.MethodGet, server.URL+path, nil)
		if err != nil {
			t.Fatal(err)
		}
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		resp, err := client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		var body map[string]any
		if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		if resp.StatusCode != wantStatus {
			t.Fatalf("GET %s: %d, want %d: %+v", path, resp.StatusCode, wantStatus, body)
		}
		return body
	}

	methodsPath := "/v1/billing/methods"
	if body := read(methodsPath, "", http.StatusOK); body["referral"] != nil {
		t.Fatalf("unconfigured service advertises referral: %+v", body)
	}
	for _, share := range []int64{17, 37} {
		service := billing.NewService(st, srv.ledger, srv.logger, billing.Config{MockMode: true, ReferralSharePercent: share})
		srv.SetBilling(service)
		if srv.Billing() != service {
			t.Fatal("router and inference must retain the same billing service")
		}
		body := read(methodsPath, "", http.StatusOK)
		referral, ok := body["referral"].(map[string]any)
		if !ok || referral["share_percent"] != float64(share) || referral["enabled"] != true {
			t.Fatalf("route retained an earlier service: %+v", body)
		}
	}
	srv.SetBilling(nil)
	if body := read(methodsPath, "", http.StatusOK); body["referral"] != nil {
		t.Fatalf("route retained cleared service: %+v", body)
	}

	rewardsPath := "/v1/admin/base-rewards"
	read(rewardsPath, "", http.StatusForbidden)
	if body := read(rewardsPath, "billing-admin", http.StatusOK); body["enabled"] != false {
		t.Fatalf("unconfigured engine is enabled: %+v", body)
	}
	for _, budget := range []int64{17_000_000, 37_000_000} {
		cfg := baserewards.DefaultConfig()
		cfg.Enabled, cfg.PoolBudgetMicroUSD = true, budget
		engine := baserewards.NewEngine(st, srv.registry, cfg, srv.logger)
		srv.SetBaseRewards(engine)
		if srv.BaseRewards() != engine {
			t.Fatal("router must retain the configured rewards engine")
		}
		body := read(rewardsPath, "billing-admin", http.StatusOK)
		if body["enabled"] != true || body["monthly_pool_budget"] != float64(budget) {
			t.Fatalf("route retained an earlier rewards engine: %+v", body)
		}
	}
	srv.SetBaseRewards(nil)
	if body := read(rewardsPath, "billing-admin", http.StatusOK); body["enabled"] != false {
		t.Fatalf("route retained cleared rewards engine: %+v", body)
	}
}

// Both API adapters and extracted endpoints use this shared policy: linked
// user identity wins over the account carrier, and a carrier alone does not
// satisfy an endpoint's linked-user requirement.
func TestBillingRequestIdentityContract(t *testing.T) {
	srv := &Server{}
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	if got := srv.resolveAccountID(req); got != "" {
		t.Fatalf("absent identity = %q", got)
	}
	req = req.WithContext(requestcontext.WithAccountID(req.Context(), "key-account"))
	if got := srv.resolveAccountID(req); got != "key-account" {
		t.Fatalf("key identity = %q", got)
	}
	w := httptest.NewRecorder()
	if user := srv.requirePrivyUser(w, req); user != nil {
		t.Fatal("account context alone supplied a linked user")
	}
	const want = "{\"error\":{\"code\":\"auth_error\",\"message\":\"this endpoint requires a Privy account — authenticate with a Privy access token\",\"type\":\"auth_error\"}}\n"
	if w.Code != http.StatusUnauthorized || w.Header().Get("Content-Type") != "application/json" || w.Body.String() != want {
		t.Fatalf("linked-user rejection changed: %d %q", w.Code, w.Body.String())
	}
	user := &store.User{AccountID: "linked-account"}
	req = req.WithContext(context.WithValue(req.Context(), auth.CtxKeyUser, user))
	if got := srv.resolveAccountID(req); got != user.AccountID {
		t.Fatalf("linked identity lost precedence: %q", got)
	}
	w = httptest.NewRecorder()
	if got := srv.requirePrivyUser(w, req); got != user || w.Body.Len() != 0 {
		t.Fatal("linked-user adapter must return the original user without writing a response")
	}
}
