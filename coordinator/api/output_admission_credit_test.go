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

	"github.com/eigeninference/d-inference/coordinator/billing"
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

// TestReconcileSettlesAgainstTheClampedCharge: a key whose OTPM (10,000) is
// below the admitted bound (32,768) is debited its burst at Commit — the
// clamped 10,000 — and settlement must credit back against THAT. An
// 8,000-token completion leaves the key bucket at 2,000 (10,000 − 8,000).
// Before the fix the reconcile credited 32,768 − 8,000 = 24,768 into the key
// bucket, the top clamp snapped it back to a full 10,000 as if nothing had
// been generated, and the key admitted the next bound-sized request at once:
// ~48K tokens/min through a 10K OTPM key. The account bucket (64,000 burst,
// charged the unclamped 32,768) still settles to 64,000 − 8,000.
func TestReconcileSettlesAgainstTheClampedCharge(t *testing.T) {
	srv, _ := testServer(t)
	tl := consumerOTPMLimiter()
	srv.SetTokenLimiters(tl, nil)
	kt := ratelimit.NewKeyTokenLimiter()
	srv.SetKeyLimiters(nil, kt)
	const keyOTPM = 10_000
	outRPM := int64(keyOTPM)
	key := &store.APIKey{ID: "key-small-otpm", OwnerAccountID: "acct-clamp", OTPMLimit: &outRPM}
	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	ctx := context.WithValue(r.Context(), ctxKeyConsumer, "acct-clamp")
	ctx = context.WithValue(ctx, ctxKeyAPIKey, key)
	r = r.WithContext(ctx)
	rps := float64(keyOTPM) / 60

	adm, ok := srv.applyTokenRateLimitWithAdmission(httptest.NewRecorder(), r, 10, 32_768, "m")
	if !ok || !adm.KeyOutputLimited || !adm.AccountOutputLimited {
		t.Fatalf("admission = %+v ok=%v, want admitted on both buckets (Peek clamps the bound to the burst)", adm, ok)
	}
	if adm.KeyOutputCharged != keyOTPM || adm.AccountOutputCharged != 32_768 {
		t.Fatalf("charged = key %d / account %d, want key %d (clamped) / account 32,768", adm.KeyOutputCharged, adm.AccountOutputCharged, keyOTPM)
	}
	if ok, _, _ := kt.Peek(key.ID, 0, 1, 0, 0, rps, keyOTPM); ok {
		t.Fatal("key bucket must be empty after committing its whole burst")
	}

	pr := &registry.PendingRequest{Model: "m", ConsumerKey: "acct-clamp", KeyID: key.ID, TokenAdmission: adm}
	srv.reconcileOutputAdmission(pr, 8_000)

	// Key bucket: 10,000 − 8,000 = 2,000 (a few tokens of refill at 166/s).
	if ok, _, _ := kt.Peek(key.ID, 0, 1_900, 0, 0, rps, keyOTPM); !ok {
		t.Fatal("after settling 8,000 of a 10,000 charge the key must have ~2,000 left; Peek(1,900) rejected")
	}
	if ok, _, _ := kt.Peek(key.ID, 0, 2_600, 0, 0, rps, keyOTPM); ok {
		t.Fatal("key bucket refilled past 10,000 − 8,000: the settlement credited the unclamped admission (32,768 − 8,000) and the top clamp hid it")
	}
	// Account bucket: 64,000 − 8,000.
	if got := remainingOutput(t, tl, "acct-clamp"); got < 64_000-8_000-5 || got > 64_000-8_000+5 {
		t.Fatalf("account remaining = %d, want ~%d", got, 64_000-8_000)
	}
}

// TestRefundPathCreditsTheChargedAmountNotTheAdmission: the pre-content
// refund returns what the bucket was debited (the clamped charge), so it
// cannot erase another in-flight request's overage. Account burst 64,000; a
// 100,000 admission (n × bound) is clamped to 64,000 → 0; another request's
// 5,000 overage debit → −5,000; the refund must land at 59,000, not snap the
// bucket to a full 64,000 by crediting 100,000.
func TestRefundPathCreditsTheChargedAmountNotTheAdmission(t *testing.T) {
	srv, _ := testServer(t)
	tl := consumerOTPMLimiter()
	srv.SetTokenLimiters(tl, nil)
	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil).WithContext(context.WithValue(context.Background(), ctxKeyConsumer, "acct-refund"))
	adm, ok := srv.applyTokenRateLimitWithAdmission(httptest.NewRecorder(), r, 10, 100_000, "m")
	if !ok {
		t.Fatal("admission rejected: Peek must clamp an oversized bound to the burst")
	}
	if adm.AccountOutputCharged != 64_000 {
		t.Fatalf("AccountOutputCharged = %d, want the clamped 64,000", adm.AccountOutputCharged)
	}
	tl.DebitOutput("acct-refund", 5_000) // another request's overage
	srv.creditUnusedOutputAdmission("acct-refund", "", adm)
	if got := remainingOutput(t, tl, "acct-refund"); got < 59_000-5 || got > 59_000+5 {
		t.Fatalf("remaining after the refund = %d, want ~59,000 (64,000 charged back, 5,000 overage kept); the unclamped 100,000 credit would read 64,000", got)
	}
}

// TestBalanceRefusalCreditsTheOTPMChargeLive drives the REAL route chain for
// both handlers with billing on and a zero balance: the token gate commits
// the injected bound (8,192) and the balance reservation then answers 402.
// The 402 is written before the handler's refundReservation closure exists,
// so before the fix the charge stayed: a low-balance consumer bouncing on
// insufficient_funds burned 8,192 OTPM per 402 and was 429'd on
// output_tokens once funded. Each 402 must leave the bucket where it was.
func TestBalanceRefusalCreditsTheOTPMChargeLive(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	t.Cleanup(srv.Close)
	// Billing on, balance 0 → every reservation is refused with 402.
	srv.SetBilling(billing.NewService(st, srv.ledger, logger, billing.Config{MockMode: true}))
	tl := consumerOTPMLimiter()
	srv.SetTokenLimiters(tl, nil)
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	const model = "broke-otpm-model"
	// The seeded admin key is an unlinked legacy key: requireAuth keys the
	// consumer (balance, token buckets) on LegacyAccountID(token), not the
	// raw token.
	account := store.LegacyAccountID("test-key")
	if got := srv.ledger.Balance(account); got != 0 {
		t.Fatalf("initial balance = %d, want 0", got)
	}
	for _, tc := range []struct{ name, endpoint, body string }{
		{"chat", "/v1/chat/completions", chatBodyWithoutMaxTokens(t, model, 0)},
		{"completions", "/v1/completions", `{"model":"` + model + `","prompt":"hello"}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			status, body, err := postGenericInference(ctx, ts.URL, tc.endpoint, tc.body)
			if err != nil {
				t.Fatalf("request: %v", err)
			}
			if status != http.StatusPaymentRequired {
				t.Fatalf("status = %d, want 402 (zero balance); body=%s", status, body)
			}
			if got := remainingOutput(t, tl, account); got < 64_000-5 {
				t.Fatalf("remaining output after the 402 = %d, want the full 64,000: the upfront OTPM charge of a request the balance gate refused was never credited back", got)
			}
		})
	}
}
