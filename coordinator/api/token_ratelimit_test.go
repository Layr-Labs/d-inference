package api

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func tokenReq(accountID string, role string) *http.Request {
	ctx := context.WithValue(context.Background(), ctxKeyConsumer, accountID)
	if role != "" {
		ctx = context.WithValue(ctx, auth.CtxKeyUser, &store.User{AccountID: accountID, Role: role})
	}
	return httptest.NewRequest("POST", "/v1/chat/completions", nil).WithContext(ctx)
}

func tokenReqWithKey(accountID string, role string, key *store.APIKey) *http.Request {
	req := tokenReq(accountID, role)
	ctx := context.WithValue(req.Context(), ctxKeyAPIKey, key)
	return req.WithContext(ctx)
}

// Consumer output-token budget trips with the output_tokens dimension and emits
// standard headers + Retry-After.
func TestApplyTokenRateLimitConsumerOTPM(t *testing.T) {
	s := &Server{
		// input generous; output tiny (burst 100, slow refill).
		consumerTokenLimiter: ratelimit.NewTokenLimiter(1000, 1_000_000, 0.01, 100),
	}

	// First request (output 100) fits.
	rec := httptest.NewRecorder()
	if !s.applyTokenRateLimit(rec, tokenReq("acct", ""), 10, 100) {
		t.Fatalf("first request should pass, got %d %s", rec.Code, rec.Body.String())
	}
	if rec.Header().Get("x-ratelimit-limit-output-tokens") == "" {
		t.Error("missing x-ratelimit-limit-output-tokens header on success")
	}

	// Second request exceeds the output bucket → 429 naming output_tokens.
	rec = httptest.NewRecorder()
	if s.applyTokenRateLimit(rec, tokenReq("acct", ""), 10, 100) {
		t.Fatal("second request should be rate limited")
	}
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "output_tokens") {
		t.Errorf("body should name output_tokens dimension: %s", rec.Body.String())
	}
	if rec.Header().Get("Retry-After") == "" {
		t.Error("missing Retry-After on 429")
	}
	if rec.Header().Get("x-ratelimit-remaining-output-tokens") == "" {
		t.Error("missing remaining-output-tokens header on 429")
	}
}

// Input-token budget trips with the input_tokens dimension.
func TestApplyTokenRateLimitConsumerITPM(t *testing.T) {
	s := &Server{
		consumerTokenLimiter: ratelimit.NewTokenLimiter(0.01, 100, 1000, 1_000_000),
	}
	rec := httptest.NewRecorder()
	if !s.applyTokenRateLimit(rec, tokenReq("acct", ""), 100, 10) {
		t.Fatal("first request should pass")
	}
	rec = httptest.NewRecorder()
	if s.applyTokenRateLimit(rec, tokenReq("acct", ""), 100, 10) {
		t.Fatal("second request should trip input limit")
	}
	if !strings.Contains(rec.Body.String(), "input_tokens") {
		t.Errorf("body should name input_tokens: %s", rec.Body.String())
	}
}

// Service accounts use the elevated limiter, so a request that would exhaust the
// consumer tier still passes.
func TestApplyTokenRateLimitServiceTier(t *testing.T) {
	s := &Server{
		consumerTokenLimiter: ratelimit.NewTokenLimiter(0.01, 100, 0.01, 100),
		serviceTokenLimiter:  ratelimit.NewTokenLimiter(1_000_000, 10_000_000, 1_000_000, 10_000_000),
	}
	// Many large requests on the service tier all pass.
	for i := 0; i < 10; i++ {
		rec := httptest.NewRecorder()
		if !s.applyTokenRateLimit(rec, tokenReq("openrouter", store.RoleService), 50_000, 50_000) {
			t.Fatalf("service request %d should pass, got %d %s", i, rec.Code, rec.Body.String())
		}
	}
	// Same load on a consumer account is throttled quickly.
	throttled := false
	for i := 0; i < 5; i++ {
		rec := httptest.NewRecorder()
		if !s.applyTokenRateLimit(rec, tokenReq("normie", ""), 50_000, 50_000) {
			throttled = true
			break
		}
	}
	if !throttled {
		t.Error("consumer account should be throttled under heavy token load")
	}
}

// Admin bypasses token limiting entirely.
func TestApplyTokenRateLimitAdminBypass(t *testing.T) {
	s := &Server{consumerTokenLimiter: ratelimit.NewTokenLimiter(0.01, 1, 0.01, 1)}
	for i := 0; i < 10; i++ {
		rec := httptest.NewRecorder()
		if !s.applyTokenRateLimit(rec, tokenReq("admin", ""), 1_000_000, 1_000_000) {
			t.Fatalf("admin request %d should always pass", i)
		}
	}
}

// A service account with no service limiter configured bypasses token limiting.
func TestApplyTokenRateLimitServiceBypassWhenUnset(t *testing.T) {
	s := &Server{consumerTokenLimiter: ratelimit.NewTokenLimiter(0.01, 1, 0.01, 1)}
	for i := 0; i < 10; i++ {
		rec := httptest.NewRecorder()
		if !s.applyTokenRateLimit(rec, tokenReq("openrouter", store.RoleService), 1_000_000, 1_000_000) {
			t.Fatalf("service request %d should bypass when no service limiter set", i)
		}
	}
}

// With no limiters configured at all, requests pass (back-compat).
func TestApplyTokenRateLimitNilLimiter(t *testing.T) {
	s := &Server{}
	rec := httptest.NewRecorder()
	if !s.applyTokenRateLimit(rec, tokenReq("acct", ""), 1_000_000, 1_000_000) {
		t.Fatal("nil limiter should pass through")
	}
}

func TestTokenExpectedOutputAdmissionServiceEnabledAvoidsUpfrontBurst(t *testing.T) {
	s := &Server{
		serviceTokenLimiter: ratelimit.NewTokenLimiter(1_000_000, 10_000_000, 0.000001, 512_000),
		outputAdmissionEstimator: ratelimit.NewOutputAdmissionEstimator(ratelimit.OutputAdmissionEstimatorConfig{
			Enabled:  true,
			Fraction: 0.25,
		}),
	}

	for i := 0; i < 16; i++ {
		rec := httptest.NewRecorder()
		if !s.applyTokenRateLimit(rec, tokenReq("openrouter", store.RoleService), 10, 32_768) {
			t.Fatalf("service request %d should pass with estimated-output admission, got %d %s", i, rec.Code, rec.Body.String())
		}
	}
}

func TestTokenExpectedOutputAdmissionDisabledUnchanged(t *testing.T) {
	s := &Server{serviceTokenLimiter: ratelimit.NewTokenLimiter(1_000_000, 10_000_000, 0.000001, 512_000)}

	for i := 0; i < 15; i++ {
		rec := httptest.NewRecorder()
		if !s.applyTokenRateLimit(rec, tokenReq("openrouter", store.RoleService), 10, 32_768) {
			t.Fatalf("service request %d should pass before burst is exhausted, got %d %s", i, rec.Code, rec.Body.String())
		}
	}
	rec := httptest.NewRecorder()
	if s.applyTokenRateLimit(rec, tokenReq("openrouter", store.RoleService), 10, 32_768) {
		t.Fatal("disabled estimator should preserve full max_tokens OTPM admission and reject request 16")
	}
	if !strings.Contains(rec.Body.String(), "output_tokens") {
		t.Fatalf("expected output_tokens rejection, got %s", rec.Body.String())
	}
}

func TestTokenExpectedOutputAdmissionDeltaConsumesFutureCapacity(t *testing.T) {
	s := &Server{
		serviceTokenLimiter: ratelimit.NewTokenLimiter(1_000_000, 10_000_000, 0.000001, 100),
		outputAdmissionEstimator: ratelimit.NewOutputAdmissionEstimator(ratelimit.OutputAdmissionEstimatorConfig{
			Enabled:  true,
			Fraction: 0.5,
		}),
	}

	rec := httptest.NewRecorder()
	admission, ok := s.applyTokenRateLimitWithAdmission(rec, tokenReq("openrouter", store.RoleService), 10, 80)
	if !ok {
		t.Fatalf("request should pass, got %d %s", rec.Code, rec.Body.String())
	}
	if admission.AdmittedOutputTokens != 40 {
		t.Fatalf("admitted output = %d, want 40", admission.AdmittedOutputTokens)
	}
	s.reconcileOutputAdmission(&registry.PendingRequest{ConsumerKey: "openrouter", Model: "m", TokenAdmission: admission}, 70)
	if ok, dim, _ := s.serviceTokenLimiter.Peek("openrouter", 0, 31); ok || dim != "output_tokens" {
		t.Fatalf("delta should consume future output capacity; peek ok=%v dim=%q", ok, dim)
	}
}

func TestTokenExpectedOutputAdmissionPerKeyOverrideStillEnforced(t *testing.T) {
	otpm := int64(100)
	s := &Server{
		serviceTokenLimiter: ratelimit.NewTokenLimiter(1_000_000, 10_000_000, 1_000_000, 10_000_000),
		keyTokenLimiter:     ratelimit.NewKeyTokenLimiter(),
		outputAdmissionEstimator: ratelimit.NewOutputAdmissionEstimator(ratelimit.OutputAdmissionEstimatorConfig{
			Enabled:  true,
			Fraction: 0.25,
		}),
	}
	key := &store.APIKey{ID: "key_1", OwnerAccountID: "openrouter", OTPMLimit: &otpm}

	for i := 0; i < 2; i++ {
		rec := httptest.NewRecorder()
		if !s.applyTokenRateLimit(rec, tokenReqWithKey("openrouter", store.RoleService, key), 10, 200) {
			t.Fatalf("per-key request %d should pass using output estimate, got %d %s", i, rec.Code, rec.Body.String())
		}
	}
	rec := httptest.NewRecorder()
	if s.applyTokenRateLimit(rec, tokenReqWithKey("openrouter", store.RoleService, key), 10, 200) {
		t.Fatal("per-key OTPM override should reject after estimated charges exhaust the key bucket")
	}
}
