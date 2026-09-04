package api

// Rate-limit and drain 429s through one writer (writeRateLimited): every one
// of them now lands in the rejection ledger (they never did — request_rejections
// had zero rate-limit rows, which is why an OTPM over-throttle was invisible),
// Retry-After is ceil(deficit) plus the shared +0..50% jitter instead of a
// floor, and the admin/service bypass branches stamp the profiler's rate-limit
// offset.

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// withConsumer stands in for requireAuth: it attaches the account id (and an
// optional user) the rate-limit middleware keys on.
func withConsumer(accountID string, user *store.User, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ctx := context.WithValue(r.Context(), ctxKeyConsumer, accountID)
		if user != nil {
			ctx = context.WithValue(ctx, auth.CtxKeyUser, user)
		}
		next(w, r.WithContext(ctx))
	}
}

func ledgerRows(t *testing.T, srv *Server, want int) []store.RejectionRecord {
	t.Helper()
	waitForRejectionCount(t, srv, want)
	return srv.store.RejectionRecordsSince(time.Time{})
}

// TestAccountRPM429_LedgerRowCeilAndJitter: the account RPM limiter's 429
// (rps 0.1, burst 1 → a 10 s deficit) answers ceil(10) + jitter ∈ [10, 15],
// X-RateLimit-Reset agrees with the header, the ledger gets a stage
// "ratelimit" / reason "requests" row carrying the same value with no model
// and no fleet walk, and 100 rejections spread over >= 3 distinct values.
func TestAccountRPM429_LedgerRowCeilAndJitter(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetRateLimiter(ratelimit.New(ratelimit.Config{RPS: 0.1, Burst: 1}))
	var served int
	h := srv.loggingMiddleware(withConsumer("acct-rpm", nil, srv.rateLimitConsumer(func(w http.ResponseWriter, r *http.Request) {
		served++
		w.WriteHeader(http.StatusOK)
	})))
	do := func() *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(minimalChatBody)))
		return rec
	}
	if rec := do(); rec.Code != http.StatusOK {
		t.Fatalf("first request = %d, want 200", rec.Code)
	}
	before := time.Now()
	rec := do()
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("second request = %d, want 429", rec.Code)
	}
	secs, err := strconv.Atoi(rec.Header().Get("Retry-After"))
	if err != nil || secs < 10 || secs > 15 {
		t.Fatalf("Retry-After = %q, want within [10, 15] (ceil of the 10 s deficit + jitter; the old floor answered 9)", rec.Header().Get("Retry-After"))
	}
	reset, err := strconv.ParseInt(rec.Header().Get("X-RateLimit-Reset"), 10, 64)
	if err != nil || reset < before.Add(time.Duration(secs)*time.Second).Unix()-1 || reset > time.Now().Add(time.Duration(secs)*time.Second).Unix()+1 {
		t.Fatalf("X-RateLimit-Reset = %q, want now + %d s", rec.Header().Get("X-RateLimit-Reset"), secs)
	}
	if !strings.Contains(rec.Body.String(), "too many requests") {
		t.Fatalf("body = %s, want the existing account RPM text", rec.Body.String())
	}
	rows := ledgerRows(t, srv, 1)
	row := rows[0]
	if row.Stage != "ratelimit" || row.ReasonCode != "requests" || row.HTTPStatus != http.StatusTooManyRequests || row.LimitKind != "consumer" {
		t.Fatalf("ledger row = %+v, want stage ratelimit / reason requests / 429 / limit_kind consumer", row)
	}
	if row.RetryAfterMs != secs*1000 || row.RequestedModel != "" || row.CouldHaveServed || row.CandidateCount != 0 {
		t.Fatalf("ledger row = %+v, want retry_after_ms %d, no model, no fleet walk", row, secs*1000)
	}
	if row.RequestID == "" {
		t.Fatal("ledger row has no coordinator request id")
	}

	// Jitter: each request gets its own coordinator-minted id.
	seen := map[int]int{}
	for i := 0; i < 100; i++ {
		rec := do()
		if rec.Code != http.StatusTooManyRequests {
			t.Fatalf("request %d = %d, want 429", i, rec.Code)
		}
		v, _ := strconv.Atoi(rec.Header().Get("Retry-After"))
		if v < 10 || v > 15 {
			t.Fatalf("request %d Retry-After = %d, want within [10, 15]", i, v)
		}
		seen[v]++
	}
	if len(seen) < 3 {
		t.Fatalf("100 rate-limit 429s produced %d distinct Retry-After values (%v); want >= 3", len(seen), seen)
	}
	if served != 1 {
		t.Fatalf("served = %d, want 1", served)
	}
}

// TestTokenRateLimit429_LedgerRowWithModel: the token gate's 429 carries the
// requested model into the ledger (it is the one rate-limit writer that knows
// it) and a ceil+jitter Retry-After: a 100-token deficit at 0.01 tok/s is
// clamped to the limiter's 60 s maximum → [60, 90].
func TestTokenRateLimit429_LedgerRowWithModel(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetTokenLimiters(ratelimit.NewTokenLimiter(1000, 1_000_000, 0.01, 100), nil)
	var last *httptest.ResponseRecorder
	h := srv.loggingMiddleware(withConsumer("acct-tok", nil, func(w http.ResponseWriter, r *http.Request) {
		if _, ok := srv.applyTokenRateLimitWithAdmission(w, r, 10, 100, "gpt-oss-20b"); ok {
			w.WriteHeader(http.StatusOK)
		}
	}))
	for i := 0; i < 2; i++ {
		last = httptest.NewRecorder()
		h.ServeHTTP(last, httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(minimalChatBody)))
	}
	if last.Code != http.StatusTooManyRequests {
		t.Fatalf("second request = %d, want 429", last.Code)
	}
	secs, err := strconv.Atoi(last.Header().Get("Retry-After"))
	if err != nil || secs < 60 || secs > 90 {
		t.Fatalf("Retry-After = %q, want within [60, 90]", last.Header().Get("Retry-After"))
	}
	if !strings.Contains(last.Body.String(), "output_tokens rate limit exceeded") {
		t.Fatalf("body = %s, want the existing token-dimension text", last.Body.String())
	}
	row := ledgerRows(t, srv, 1)[0]
	if row.Stage != "ratelimit" || row.ReasonCode != "output_tokens" || row.RequestedModel != "gpt-oss-20b" || row.LimitKind != "consumer" {
		t.Fatalf("ledger row = %+v, want stage ratelimit / reason output_tokens / model gpt-oss-20b / consumer", row)
	}
	if row.RetryAfterMs != secs*1000 || row.CouldHaveServed {
		t.Fatalf("ledger row = %+v, want retry_after_ms %d and no fleet walk", row, secs*1000)
	}
}

// TestKeyRPM429_LedgerRow: the per-key RPM override's 429 is a ledger row
// too (stage ratelimit, reason requests, limit_kind key).
func TestKeyRPM429_LedgerRow(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetKeyLimiters(ratelimit.New(ratelimit.Config{RPS: 1, Burst: 1}), nil)
	rpm := int64(1)
	key := &store.APIKey{ID: "key-1", RPMLimit: &rpm}
	h := srv.loggingMiddleware(withConsumer("acct-key", nil, func(w http.ResponseWriter, r *http.Request) {
		r = r.WithContext(context.WithValue(r.Context(), ctxKeyAPIKey, key))
		if srv.applyKeyRPMLimit(w, r) {
			w.WriteHeader(http.StatusOK)
		}
	}))
	var last *httptest.ResponseRecorder
	for i := 0; i < 2; i++ {
		last = httptest.NewRecorder()
		h.ServeHTTP(last, httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(minimalChatBody)))
	}
	if last.Code != http.StatusTooManyRequests {
		t.Fatalf("second request = %d, want 429", last.Code)
	}
	secs, err := strconv.Atoi(last.Header().Get("Retry-After"))
	if err != nil || secs < 1 {
		t.Fatalf("Retry-After = %q, want a positive integer", last.Header().Get("Retry-After"))
	}
	if !strings.Contains(last.Body.String(), "API key request rate limit exceeded") {
		t.Fatalf("body = %s, want the existing key RPM text", last.Body.String())
	}
	row := ledgerRows(t, srv, 1)[0]
	if row.Stage != "ratelimit" || row.ReasonCode != "requests" || row.LimitKind != "key" || row.KeyID != "key-1" || row.RetryAfterMs != secs*1000 {
		t.Fatalf("ledger row = %+v, want stage ratelimit / reason requests / key / key-1 / %d ms", row, secs*1000)
	}
}

// TestRateLimitBypassStampsProfiler: the admin and service-without-limiter
// bypass branches record the profiler's rate-limit offset, so
// RatelimitDoneUS is never 0 for the traffic that skips the limiter.
func TestRateLimitBypassStampsProfiler(t *testing.T) {
	srv, _ := testServer(t)
	if !srv.profilerEnabled() {
		t.Fatal("profiler must be on for this test")
	}
	srv.SetRateLimiter(ratelimit.New(ratelimit.Config{RPS: 1, Burst: 1}))
	srv.SetServiceRateLimiter(nil)
	check := func(name, account string, user *store.User) {
		t.Helper()
		var stamped int64
		h := srv.loggingMiddleware(withConsumer(account, user, srv.rateLimitConsumer(func(w http.ResponseWriter, r *http.Request) {
			if m := requestMetaFromContext(r.Context()); m != nil {
				stamped = m.ratelimitDoneUS
			}
			w.WriteHeader(http.StatusOK)
		})))
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(minimalChatBody)))
		if rec.Code != http.StatusOK {
			t.Fatalf("%s: status = %d, want 200", name, rec.Code)
		}
		if stamped <= 0 {
			t.Fatalf("%s: ratelimitDoneUS = %d, want > 0 on the bypass branch", name, stamped)
		}
	}
	check("admin bypass", "admin", nil)
	check("service bypass without a service limiter", "openrouter", &store.User{AccountID: "openrouter", Role: store.RoleService})
}

// TestRateLimit429RowsBatchThroughTheSink drives the production writer
// (writeRateLimited -> recordRejection) over NewServer's real sink with a
// store that counts its calls: 200 rate-limit 429s become a handful of
// multi-row inserts and zero single-row writes, and every row lands. Before
// the change each 429 queued its own single-row closure (200 store round
// trips on the one worker), the pattern that let a throttled key starve
// served requests' route rows.
func TestRateLimit429RowsBatchThroughTheSink(t *testing.T) {
	st := newCountingTelemetryStore()
	logger := quietLogger()
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)
	t.Cleanup(srv.Close)
	if srv.routeTelemetry == nil {
		t.Fatal("NewServer must install the telemetry sink")
	}
	const n = 200
	for i := 0; i < n; i++ {
		rec := httptest.NewRecorder()
		r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(minimalChatBody))
		r = r.WithContext(context.WithValue(r.Context(), ctxKeyConsumer, "acct-storm"))
		srv.writeRateLimited(rec, r, "ratelimit", "consumer", "requests", 3, "", "requests rate limit exceeded")
		if rec.Code != http.StatusTooManyRequests {
			t.Fatalf("status = %d, want 429", rec.Code)
		}
	}
	if !srv.routeTelemetry.closeAndWait(5 * time.Second) {
		t.Fatal("sink did not drain")
	}
	batches, rows := st.count("rejections")
	if rows != n || batches == 0 || batches > 8 {
		t.Fatalf("rejection batches: calls=%d rows=%d, want all %d rows in a few multi-row inserts; log=%v", batches, rows, n, st.callLog())
	}
	if singles, _ := st.count("rejection"); singles != 0 {
		t.Fatalf("%d single-row rejection writes on the sink worker, want 0; log=%v", singles, st.callLog())
	}
	got := st.RejectionRecordsSince(time.Time{})
	if len(got) != n {
		t.Fatalf("persisted %d rows, want %d", len(got), n)
	}
	if got[0].Stage != "ratelimit" || got[0].ReasonCode != "requests" || got[0].RetryAfterMs != 3000 || got[0].LimitKind != "consumer" {
		t.Fatalf("row = %+v, want stage ratelimit / reason requests / retry_after_ms 3000 / limit_kind consumer", got[0])
	}
}
