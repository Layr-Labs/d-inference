package access

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// serviceRequest builds a request whose context carries a service-role user.
func serviceRequest(accountID string) *http.Request {
	user := &store.User{AccountID: accountID, Role: store.RoleService}
	ctx := WithConsumer(context.Background(), accountID)
	ctx = context.WithValue(ctx, auth.CtxKeyUser, user)
	return httptest.NewRequest("POST", "/v1/chat/completions", nil).WithContext(ctx)
}

// A service account must use the elevated limiter, not the (tiny) consumer one.
func TestRateLimitServiceUsesElevatedLimiter(t *testing.T) {
	s := &Owner{
		rateLimiter:        ratelimit.New(ratelimit.Config{RPS: 0.01, Burst: 1}),
		serviceRateLimiter: ratelimit.New(ratelimit.Config{RPS: 100, Burst: 50}),
	}
	h := s.RateLimitConsumer(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusOK) })

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
			WithContext(WithConsumer(context.Background(), "normie"))
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
	s := &Owner{
		financialRateLimiter: ratelimit.New(ratelimit.Config{RPS: 0.001, Burst: 1}),
		serviceRateLimiter:   ratelimit.New(ratelimit.Config{RPS: 1000, Burst: 1000}),
	}
	h := s.RateLimitFinancial(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusOK) })

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
	s := &Owner{rateLimiter: ratelimit.New(ratelimit.Config{RPS: 0.001, Burst: 1})}
	h := s.RateLimitConsumer(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusOK) })

	for i := 0; i < 10; i++ {
		rec := httptest.NewRecorder()
		h(rec, serviceRequest("openrouter"))
		if rec.Code != http.StatusOK {
			t.Fatalf("service bypass request %d got %d, want 200", i, rec.Code)
		}
	}
}
