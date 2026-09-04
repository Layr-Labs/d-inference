package ratelimit

// CreditN / CreditOutput: the settlement twin of DebitOutput. The OTPM gate
// charges the forwarded max_tokens bound upfront; crediting the unused part
// back must restore capacity immediately, never push a bucket above its
// burst, and mirror on the per-key limiter.

import (
	"testing"
	"time"
)

// Allow(32,768) twice on a 64,000 burst leaves 0; Credit(32,206) — a 562-token
// completion's unused charge — makes a third Allow(32,768) pass immediately.
func TestCreditNRestoresCapacity(t *testing.T) {
	l := New(Config{RPS: 500_000.0 / 60, Burst: 64_000})
	for i := 0; i < 1; i++ {
		if ok, _ := l.AllowN("acct", 32_768); !ok {
			t.Fatalf("admission %d rejected", i+1)
		}
	}
	if ok, _ := l.AllowN("acct", 32_768); ok {
		t.Fatal("second 32,768 admission should be rejected on a 64,000 burst with ~31K left")
	}
	l.CreditN("acct", 32_206)
	if ok, retry := l.AllowN("acct", 32_768); !ok {
		t.Fatalf("after crediting 32,206 the next 32,768 admission must pass immediately (retry-after %v)", retry)
	}
	// Degenerate inputs are no-ops.
	l.CreditN("", 10)
	l.CreditN("acct", 0)
	l.CreditN("acct", -5)
}

// A credit can never lift a bucket above its burst: the next read clamps.
func TestCreditNeverExceedsBurst(t *testing.T) {
	l := New(Config{RPS: 1, Burst: 100})
	l.CreditN("acct", 1_000_000)
	if st := l.Stat("acct"); st.Remaining != 100 {
		t.Fatalf("Remaining after an oversized credit = %d, want the burst 100", st.Remaining)
	}
	if ok, _ := l.AllowN("acct", 100); !ok {
		t.Fatal("a full bucket must admit its burst")
	}
	if ok, _ := l.AllowN("acct", 1); ok {
		t.Fatal("the credit above burst must have been lost at the top")
	}
	// Credit exactly what was consumed → back to full, and not beyond.
	l.CreditN("acct", 100)
	l.CreditN("acct", 100)
	if st := l.Stat("acct"); st.Remaining != 100 {
		t.Fatalf("Remaining after double credit = %d, want 100", st.Remaining)
	}
}

// TokenLimiter.CreditOutput is the account-level twin of DebitOutput.
func TestTokenLimiterCreditOutput(t *testing.T) {
	tl := NewTokenLimiter(1000, 1_000_000, 500_000.0/60, 64_000)
	if ok, _, _ := tl.Allow("acct", 10, 32_768); !ok {
		t.Fatal("first admission rejected")
	}
	if ok, dim, _ := tl.Allow("acct", 10, 32_768); ok || dim != "output_tokens" {
		t.Fatalf("second admission = (%v, %q), want rejected on output_tokens", ok, dim)
	}
	tl.CreditOutput("acct", 32_206)
	if ok, _, _ := tl.Allow("acct", 10, 32_768); !ok {
		t.Fatal("after the credit the next admission must pass")
	}
	// Unlimited output dimension: no-op, never panics.
	NewTokenLimiter(1000, 1_000_000, 0, 0).CreditOutput("acct", 5)
	// Never above burst.
	tl.CreditOutput("acct", 10_000_000)
	if st, ok := tl.OutputStat("acct"); !ok || st.Remaining != 64_000 {
		t.Fatalf("OutputStat after an oversized credit = %+v/%v, want Remaining 64,000", st, ok)
	}
	time.Sleep(time.Millisecond)
}

// KeyTokenLimiter.CreditOutput mirrors on the per-key bucket at the key's rate.
func TestKeyTokenLimiterCreditOutput(t *testing.T) {
	kt := NewKeyTokenLimiter()
	const rps, burst = 10.0, 1_000
	if ok, _, _ := kt.Allow("k", 1, 900, 1000, 100_000, rps, burst); !ok {
		t.Fatal("first admission rejected")
	}
	if ok, dim, _ := kt.Allow("k", 1, 900, 1000, 100_000, rps, burst); ok || dim != "output_tokens" {
		t.Fatalf("second admission = (%v, %q), want rejected on output_tokens", ok, dim)
	}
	kt.CreditOutput("k", 850, rps, burst)
	if ok, _, _ := kt.Allow("k", 1, 900, 1000, 100_000, rps, burst); !ok {
		t.Fatal("after the credit the next admission must pass")
	}
	// Unlimited key dimension: no-op.
	kt.CreditOutput("k", 5, 0, 0)
	kt.CreditOutput("", 5, rps, burst)
}

// tokensAt reads the raw bucket level (negative while in debt) — Stat clamps
// at zero, so it cannot tell a dropped credit from a landed one.
func tokensAt(t *testing.T, l *Limiter, key string) float64 {
	t.Helper()
	l.mu.Lock()
	e := l.buckets[key]
	l.mu.Unlock()
	if e == nil {
		t.Fatalf("no bucket for %q", key)
	}
	return e.limiter.TokensAt(time.Now())
}

// TestCreditNLandsWhileInDebt: a bucket driven negative (the always-landing
// Commit, an overage DebitOutput) must still absorb a partial credit. Before
// the fix CreditN went through AllowN, whose zero future-reserve refuses a
// reservation that leaves the bucket negative, so the credit was dropped
// while the counter still reported it: 64K burst, 5,000 left, DebitN 11,000
// → −6,000; CreditN 1,700 stayed at −6,000 instead of −4,300.
func TestCreditNLandsWhileInDebt(t *testing.T) {
	// A negligible refill so the arithmetic below is exact over the test.
	l := New(Config{RPS: 0.001, Burst: 64_000})
	if ok, _ := l.AllowN("acct", 59_000); !ok {
		t.Fatal("initial 59,000 admission rejected on a full 64,000 bucket")
	}
	l.DebitN("acct", 11_000)
	if got := tokensAt(t, l, "acct"); got > -5_990 || got < -6_010 {
		t.Fatalf("after the debit tokens = %.0f, want ~-6,000", got)
	}
	l.CreditN("acct", 1_700)
	if got := tokensAt(t, l, "acct"); got > -4_290 || got < -4_310 {
		t.Fatalf("partial credit into debt: tokens = %.0f, want ~-4,300 (the credit was dropped)", got)
	}
	// Behavioural twin: three partial credits reach +100 only if each landed.
	l.CreditN("acct", 4_300)
	l.CreditN("acct", 100)
	if !l.CanN("acct", 100) {
		t.Fatalf("after crediting back to +100 CanN(100) is false: tokens = %.0f", tokensAt(t, l, "acct"))
	}
	if l.CanN("acct", 101) {
		t.Fatalf("CanN(101) true: credited more than the sum of credits (tokens = %.0f)", tokensAt(t, l, "acct"))
	}
}

// TestCreditNWithRateLandsWhileInDebt is the per-key twin.
func TestCreditNWithRateLandsWhileInDebt(t *testing.T) {
	const rps, burst = 0.001, 10_000
	l := New(Config{})
	if ok, _ := l.AllowNWithRate("k", 9_000, rps, burst); !ok {
		t.Fatal("initial admission rejected")
	}
	l.DebitNWithRate("k", 3_000, rps, burst) // → -2,000
	if got := tokensAt(t, l, "k"); got > -1_990 || got < -2_010 {
		t.Fatalf("after the debit tokens = %.0f, want ~-2,000", got)
	}
	l.CreditNWithRate("k", 500, rps, burst)
	if got := tokensAt(t, l, "k"); got > -1_490 || got < -1_510 {
		t.Fatalf("partial credit into debt: tokens = %.0f, want ~-1,500 (the credit was dropped)", got)
	}
	l.CreditNWithRate("k", 1_500, rps, burst)
	l.CreditNWithRate("k", 50, rps, burst)
	if !l.CanNWithRate("k", 50, rps, burst) || l.CanNWithRate("k", 51, rps, burst) {
		t.Fatalf("credits did not sum: tokens = %.0f, want ~50", tokensAt(t, l, "k"))
	}
	// Still clamped at the burst on the way up.
	l.CreditNWithRate("k", 1_000_000, rps, burst)
	if got := tokensAt(t, l, "k"); got > burst+1 {
		t.Fatalf("credit above burst: tokens = %.0f, want <= %d", got, burst)
	}
}
