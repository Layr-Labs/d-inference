package api

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/eigeninference/coordinator/internal/ratelimit"
)

// rateLimitConsumer must short-circuit when no limiter is configured so
// existing tests and callers that don't set one continue to work.
func TestRateLimitNilLimiterPassesThrough(t *testing.T) {
	s := &Server{}
	called := false
	h := s.rateLimitConsumer(func(w http.ResponseWriter, r *http.Request) {
		called = true
		w.WriteHeader(http.StatusOK)
	})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest("POST", "/v1/chat/completions", nil).
		WithContext(context.WithValue(context.Background(), ctxKeyConsumer, "acct-1"))
	h(rec, req)

	if !called {
		t.Fatal("handler should be called when limiter is nil")
	}
	if rec.Code != http.StatusOK {
		t.Errorf("status = %d, want 200", rec.Code)
	}
}

// Admin pseudo-account from requireAuth must bypass rate limiting so ops
// scripts and admin tooling don't get throttled.
func TestRateLimitAdminBypasses(t *testing.T) {
	s := &Server{rateLimiter: ratelimit.New(ratelimit.Config{RPS: 0.001, Burst: 1})}
	h := s.rateLimitConsumer(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	for i := 0; i < 10; i++ {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest("POST", "/v1/chat/completions", nil).
			WithContext(context.WithValue(context.Background(), ctxKeyConsumer, "admin"))
		h(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("admin request %d got %d, want 200", i, rec.Code)
		}
	}
}

// Once burst is exhausted the middleware must return 429 with Retry-After.
func TestRateLimitReturns429AfterBurst(t *testing.T) {
	s := &Server{rateLimiter: ratelimit.New(ratelimit.Config{RPS: 0.01, Burst: 2})}
	h := s.rateLimitConsumer(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	makeReq := func() *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest("POST", "/v1/chat/completions", nil).
			WithContext(context.WithValue(context.Background(), ctxKeyConsumer, "acct-burst"))
		h(rec, req)
		return rec
	}

	if rec := makeReq(); rec.Code != http.StatusOK {
		t.Fatalf("req 1 status = %d, want 200", rec.Code)
	}
	if rec := makeReq(); rec.Code != http.StatusOK {
		t.Fatalf("req 2 status = %d, want 200", rec.Code)
	}
	rec := makeReq()
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("req 3 status = %d, want 429", rec.Code)
	}
	if got := rec.Header().Get("Retry-After"); got == "" {
		t.Error("Retry-After header missing on 429")
	}
}
