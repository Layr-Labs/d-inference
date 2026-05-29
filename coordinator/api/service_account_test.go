package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// serviceRequest builds a request whose context carries a service-role user.
func serviceRequest(accountID string) *http.Request {
	user := &store.User{AccountID: accountID, Role: store.RoleService}
	ctx := context.WithValue(context.Background(), ctxKeyConsumer, accountID)
	ctx = context.WithValue(ctx, auth.CtxKeyUser, user)
	return httptest.NewRequest("POST", "/v1/chat/completions", nil).WithContext(ctx)
}

// A service account must use the elevated limiter, not the (tiny) consumer one.
func TestRateLimitServiceUsesElevatedLimiter(t *testing.T) {
	s := &Server{
		rateLimiter:        ratelimit.New(ratelimit.Config{RPS: 0.01, Burst: 1}),
		serviceRateLimiter: ratelimit.New(ratelimit.Config{RPS: 100, Burst: 50}),
	}
	h := s.rateLimitConsumer(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusOK) })

	for i := 0; i < 20; i++ {
		rec := httptest.NewRecorder()
		h(rec, serviceRequest("openrouter"))
		if rec.Code != http.StatusOK {
			t.Fatalf("service request %d got %d, want 200 (elevated limiter)", i, rec.Code)
		}
	}

	// A normal account on the same tiny consumer limiter is throttled fast.
	throttled := false
	for i := 0; i < 5; i++ {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest("POST", "/v1/chat/completions", nil).
			WithContext(context.WithValue(context.Background(), ctxKeyConsumer, "normie"))
		h(rec, req)
		if rec.Code == http.StatusTooManyRequests {
			throttled = true
			break
		}
	}
	if !throttled {
		t.Error("expected a normal account to be throttled by the consumer limiter")
	}
}

// Service-role elevation must NOT apply to financial endpoints — those keep the
// strict financial limiter for every account (abuse guard on balance mutations).
func TestRateLimitFinancialNotElevatedForService(t *testing.T) {
	s := &Server{
		financialRateLimiter: ratelimit.New(ratelimit.Config{RPS: 0.001, Burst: 1}),
		serviceRateLimiter:   ratelimit.New(ratelimit.Config{RPS: 1000, Burst: 1000}),
	}
	h := s.rateLimitFinancial(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusOK) })

	// A service account on a financial route: first request ok, second throttled
	// by the strict financial limiter (not the elevated service limiter).
	rec1 := httptest.NewRecorder()
	h(rec1, serviceRequest("openrouter"))
	if rec1.Code != http.StatusOK {
		t.Fatalf("first financial request = %d, want 200", rec1.Code)
	}
	rec2 := httptest.NewRecorder()
	h(rec2, serviceRequest("openrouter"))
	if rec2.Code != http.StatusTooManyRequests {
		t.Fatalf("service account on financial endpoint = %d, want 429 (strict limiter applies)", rec2.Code)
	}
}

// With no service limiter configured, service accounts bypass rate limiting.
func TestRateLimitServiceBypassesWhenNoServiceLimiter(t *testing.T) {
	s := &Server{rateLimiter: ratelimit.New(ratelimit.Config{RPS: 0.001, Burst: 1})}
	h := s.rateLimitConsumer(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusOK) })

	for i := 0; i < 10; i++ {
		rec := httptest.NewRecorder()
		h(rec, serviceRequest("openrouter"))
		if rec.Code != http.StatusOK {
			t.Fatalf("service bypass request %d got %d, want 200", i, rec.Code)
		}
	}
}

func TestAdminSetUserRole(t *testing.T) {
	srv, st := testBillingServer(t)
	srv.SetAdminKey("admin-key")
	if err := st.CreateUser(&store.User{AccountID: "acct-or", PrivyUserID: "did:privy:or"}); err != nil {
		t.Fatal(err)
	}

	call := func(body string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPut, "/v1/admin/users/role", strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer admin-key")
		rec := httptest.NewRecorder()
		srv.handleAdminSetUserRole(rec, req)
		return rec
	}

	// Grant service role.
	if rec := call(`{"account_id":"acct-or","role":"service"}`); rec.Code != http.StatusOK {
		t.Fatalf("grant role status = %d body = %s", rec.Code, rec.Body.String())
	}
	u, _ := st.GetUserByAccountID("acct-or")
	if u.Role != store.RoleService {
		t.Errorf("role = %q, want service", u.Role)
	}

	// Invalid role rejected.
	if rec := call(`{"account_id":"acct-or","role":"superadmin"}`); rec.Code != http.StatusBadRequest {
		t.Errorf("invalid role status = %d, want 400", rec.Code)
	}

	// Missing account_id rejected.
	if rec := call(`{"role":"service"}`); rec.Code != http.StatusBadRequest {
		t.Errorf("missing account status = %d, want 400", rec.Code)
	}

	// Unknown user → 404.
	if rec := call(`{"account_id":"ghost","role":"service"}`); rec.Code != http.StatusNotFound {
		t.Errorf("unknown user status = %d, want 404", rec.Code)
	}
}

func TestAdminSetUserRoleRequiresAdmin(t *testing.T) {
	srv, st := testBillingServer(t)
	srv.SetAdminKey("admin-key")
	_ = st.CreateUser(&store.User{AccountID: "acct-or", PrivyUserID: "did:privy:or"})

	req := httptest.NewRequest(http.MethodPut, "/v1/admin/users/role", strings.NewReader(`{"account_id":"acct-or","role":"service"}`))
	req.Header.Set("Authorization", "Bearer wrong-key")
	rec := httptest.NewRecorder()
	srv.handleAdminSetUserRole(rec, req)
	if rec.Code == http.StatusOK {
		t.Errorf("non-admin got %d, want non-200", rec.Code)
	}
}

func TestAdminSetUserPlatformFee(t *testing.T) {
	srv, st := testBillingServer(t)
	srv.SetAdminKey("admin-key")
	if err := st.CreateUser(&store.User{AccountID: "acct-or", PrivyUserID: "did:privy:or"}); err != nil {
		t.Fatal(err)
	}

	call := func(body string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPut, "/v1/admin/users/platform-fee", strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer admin-key")
		rec := httptest.NewRecorder()
		srv.handleAdminSetUserPlatformFee(rec, req)
		return rec
	}

	// Waive the fee (0%).
	if rec := call(`{"account_id":"acct-or","platform_fee_percent":0}`); rec.Code != http.StatusOK {
		t.Fatalf("set 0%% status = %d body = %s", rec.Code, rec.Body.String())
	}
	u, _ := st.GetUserByAccountID("acct-or")
	if u.PlatformFeePercent == nil || *u.PlatformFeePercent != 0 {
		t.Errorf("fee override = %v, want 0", u.PlatformFeePercent)
	}

	// Clear override (omitted field → nil).
	if rec := call(`{"account_id":"acct-or"}`); rec.Code != http.StatusOK {
		t.Fatalf("clear status = %d body = %s", rec.Code, rec.Body.String())
	}
	u, _ = st.GetUserByAccountID("acct-or")
	if u.PlatformFeePercent != nil {
		t.Errorf("fee after clear = %v, want nil", *u.PlatformFeePercent)
	}

	// Out-of-range rejected.
	if rec := call(`{"account_id":"acct-or","platform_fee_percent":150}`); rec.Code != http.StatusBadRequest {
		t.Errorf("out-of-range status = %d, want 400", rec.Code)
	}

	// Response shape for a set value.
	rec := call(`{"account_id":"acct-or","platform_fee_percent":3}`)
	var resp map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp["status"] != "platform_fee_updated" {
		t.Errorf("status field = %v", resp["status"])
	}
}
