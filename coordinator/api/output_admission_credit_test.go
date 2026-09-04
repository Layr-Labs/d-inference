package api

// OTPM admission honesty, part A: the upfront output charge (the forwarded
// max_tokens bound) is credited back at settlement for the unused part, and
// in full when the request ends before any content — exactly once per
// admission. Part B (charging the expected output for every tier) is gated on
// the DD read of service-tier output_tokens rejections and T10-02's warm
// calibrator, and is not in this change.

import (
	"context"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func consumerOTPMLimiter() *ratelimit.TokenLimiter {
	// The production consumer defaults: ITPM 5M/1M burst, OTPM 500K/64K burst.
	return ratelimit.NewTokenLimiter(5_000_000.0/60, 1_000_000, 500_000.0/60, 64_000)
}

func remainingOutput(t *testing.T, tl *ratelimit.TokenLimiter, account string) int {
	t.Helper()
	st, ok := tl.OutputStat(account)
	if !ok {
		t.Fatal("output dimension not enforced")
	}
	return st.Remaining
}

// TestReconcileOutputAdmissionCreditsUnused: a 32,768-token admission settled
// by a 300-token completion returns 32,468 to the account AND key buckets, so
// the next 32,768 admission passes (before: the third such request 429'd) and
// the NEXT request's x-ratelimit-remaining-output-tokens shows the credit
// (the header is set at admission, so the settled request itself never does).
// An overage still debits.
func TestReconcileOutputAdmissionCreditsUnused(t *testing.T) {
	srv, _ := testServer(t)
	tl := consumerOTPMLimiter()
	srv.SetTokenLimiters(tl, nil)
	kt := ratelimit.NewKeyTokenLimiter()
	srv.SetKeyLimiters(nil, kt)
	outRPM := int64(500_000)
	key := &store.APIKey{ID: "key-otpm", OwnerAccountID: "acct", OTPMLimit: &outRPM}
	req := func() *http.Request {
		r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
		ctx := context.WithValue(r.Context(), ctxKeyConsumer, "acct")
		ctx = context.WithValue(ctx, ctxKeyAPIKey, key)
		return r.WithContext(ctx)
	}
	admit := func(outputTokens int) (registry.TokenAdmission, *httptest.ResponseRecorder, bool) {
		rec := httptest.NewRecorder()
		adm, ok := srv.applyTokenRateLimitWithAdmission(rec, req(), 10, outputTokens, "m")
		return adm, rec, ok
	}

	first, _, ok := admit(32_768)
	if !ok || !first.TracksOutput() || !first.AccountOutputLimited || !first.KeyOutputLimited {
		t.Fatalf("first admission = %+v ok=%v, want admitted and tracked on both buckets", first, ok)
	}
	if _, _, ok := admit(32_768); ok {
		t.Fatal("second 32,768 admission must be rejected on a 64,000 burst (~31K left)")
	}
	before := remainingOutput(t, tl, "acct")
	pr := &registry.PendingRequest{Model: "m", ConsumerKey: "acct", KeyID: "key-otpm", TokenAdmission: first}
	srv.reconcileOutputAdmission(pr, 300)
	after := remainingOutput(t, tl, "acct")
	if got := after - before; got < 32_468-5 || got > 32_468+5 {
		t.Fatalf("account bucket credit = %d, want ~32,468 (32,768 admitted − 300 used)", got)
	}
	// A second settlement of the same admission is a no-op (once-guard).
	srv.reconcileOutputAdmission(pr, 300)
	if again := remainingOutput(t, tl, "acct"); again > after+5 {
		t.Fatalf("second reconcile credited again: %d -> %d", after, again)
	}
	// Both buckets: the next 32,768 admission passes and the NEXT request's
	// header reflects the credit.
	second, rec, ok := admit(32_768)
	if !ok {
		t.Fatalf("after the credit the next 32,768 admission must pass; body=%s", rec.Body.String())
	}
	hdr, err := strconv.Atoi(rec.Header().Get("x-ratelimit-remaining-output-tokens"))
	if err != nil || hdr < 64_000-300-32_768-5 || hdr > 64_000-300-32_768+5 {
		t.Fatalf("x-ratelimit-remaining-output-tokens = %q, want ~%d (burst − 300 settled − 32,768 admitted)", rec.Header().Get("x-ratelimit-remaining-output-tokens"), 64_000-300-32_768)
	}
	// Overage still debits: 33,000 actual on a 32,768 admission → −232.
	pr2 := &registry.PendingRequest{Model: "m", ConsumerKey: "acct", KeyID: "key-otpm", TokenAdmission: second}
	before = remainingOutput(t, tl, "acct")
	srv.reconcileOutputAdmission(pr2, 33_000)
	if got := before - remainingOutput(t, tl, "acct"); got < 232-5 || got > 232+5 {
		t.Fatalf("overage debit = %d, want ~232", got)
	}
}

// TestRefundPathCreditsAdmissionOnce: a request that ends before content
// (the handler's refundReservation closure) returns the WHOLE admitted output
// once — a second refund call and a later reconcile are no-ops.
func TestRefundPathCreditsAdmissionOnce(t *testing.T) {
	srv, _ := testServer(t)
	tl := consumerOTPMLimiter()
	srv.SetTokenLimiters(tl, nil)
	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil).WithContext(context.WithValue(context.Background(), ctxKeyConsumer, "acct"))
	adm, ok := srv.applyTokenRateLimitWithAdmission(httptest.NewRecorder(), r, 10, 32_768, "m")
	if !ok {
		t.Fatal("admission rejected")
	}
	charged := remainingOutput(t, tl, "acct")
	if charged > 64_000-32_768+5 {
		t.Fatalf("remaining after admission = %d, want ~%d", charged, 64_000-32_768)
	}
	srv.creditUnusedOutputAdmission("acct", "", adm)
	restored := remainingOutput(t, tl, "acct")
	if restored < 64_000-5 {
		t.Fatalf("remaining after the refund-path credit = %d, want the full burst back", restored)
	}
	srv.creditUnusedOutputAdmission("acct", "", adm)
	srv.reconcileOutputAdmission(&registry.PendingRequest{Model: "m", ConsumerKey: "acct", TokenAdmission: adm}, 5)
	if again := remainingOutput(t, tl, "acct"); again != restored && again > restored+5 {
		t.Fatalf("a second settlement moved the bucket: %d -> %d", restored, again)
	}
	// A zero admission (no guard) is inert on both paths.
	srv.creditUnusedOutputAdmission("acct", "", registry.TokenAdmission{})
	srv.reconcileOutputAdmission(&registry.PendingRequest{Model: "m", ConsumerKey: "acct"}, 5)
}

// TestOmittedMaxTokensSequentialRequestsNoLongerExhaustOTPMLive drives the
// REAL HTTP path with a real WS provider at the production consumer OTPM
// defaults (500K/min, 64K burst): 20 sequential chat requests that omit
// max_tokens — each admitted at the injected 8,192 bound and settled by a
// 3-token completion — all succeed. Before the credit the 8th request 429'd
// ("output_tokens rate limit exceeded"): 7 × 8,192 exhausted the burst and
// nothing came back until the minute refilled.
func TestOmittedMaxTokensSequentialRequestsNoLongerExhaustOTPMLive(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	t.Cleanup(srv.Close)
	srv.SetTokenLimiters(consumerOTPMLimiter(), nil)
	srv.challengeInterval = time.Hour
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	const model = "otpm-credit-model"
	startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "otpm-provider", Version: "0.8.10", DecodeTPS: 40,
		Models: []failoverModelSpec{{ID: model}}, Script: fullServeScript(model),
	})
	for i := 0; i < 20; i++ {
		status, body, err := postChat(ctx, ts.URL, "test-key", chatBodyWithoutMaxTokens(t, model, 0))
		if err != nil {
			t.Fatalf("request %d: %v", i+1, err)
		}
		if status != http.StatusOK {
			t.Fatalf("request %d: status=%d body=%s (the upfront 8,192 charge must be credited back at settlement)", i+1, status, body)
		}
	}
}
