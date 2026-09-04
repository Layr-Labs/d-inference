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
