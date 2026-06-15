package ratelimit

import (
	"sync"
	"sync/atomic"
	"testing"
)

func TestAllowN(t *testing.T) {
	// Slow refill, burst 10. One AllowN(10) drains the bucket.
	l := New(Config{RPS: 0.01, Burst: 10})
	if ok, _ := l.AllowN("acct", 10); !ok {
		t.Fatal("AllowN(10) should succeed on a full burst-10 bucket")
	}
	if ok, retry := l.AllowN("acct", 1); ok {
		t.Fatal("AllowN(1) should fail after the bucket is drained")
	} else if retry <= 0 {
		t.Error("expected a positive Retry-After on rejection")
	}

	// Empty account and non-positive n are always allowed.
	if ok, _ := l.AllowN("", 1000); !ok {
		t.Error("empty account should bypass")
	}
	if ok, _ := l.AllowN("acct", 0); !ok {
		t.Error("n=0 should be allowed")
	}
}

func TestTokenLimiterDimensions(t *testing.T) {
	// input burst 100, output burst 50, slow refill.
	tl := NewTokenLimiter(0.01, 100, 0.01, 50)

	// First request consumes input=80, output=40 — fits.
	if ok, dim, _ := tl.Allow("a", 80, 40); !ok {
		t.Fatalf("first request should pass, got dim=%q", dim)
	}
	// Next request needs input=80 but only ~20 remain → input_tokens trips.
	ok, dim, retry := tl.Allow("a", 80, 5)
	if ok || dim != "input_tokens" {
		t.Fatalf("expected input_tokens rejection, got ok=%v dim=%q", ok, dim)
	}
	if retry <= 0 {
		t.Error("expected positive Retry-After")
	}

	// Separate account: exhaust output only.
	if ok, _, _ := tl.Allow("b", 0, 50); !ok {
		t.Fatal("output=50 should fit a fresh burst-50 bucket")
	}
	if ok, dim, _ := tl.Allow("b", 0, 10); ok || dim != "output_tokens" {
		t.Fatalf("expected output_tokens rejection, got ok=%v dim=%q", ok, dim)
	}
}

func TestTokenLimiterClampsToBurst(t *testing.T) {
	// A request larger than the burst must still pass once (clamped), not be
	// rejected forever.
	tl := NewTokenLimiter(0.01, 100, 0.01, 100)
	if ok, dim, _ := tl.Allow("a", 1_000_000, 1_000_000); !ok {
		t.Fatalf("oversized request should pass once via clamping, got dim=%q", dim)
	}
	// Bucket now drained; a second oversized request is rejected.
	if ok, _, _ := tl.Allow("a", 1_000_000, 0); ok {
		t.Fatal("second oversized request should be rejected")
	}
}

// A zero/negative dimension must be treated as unlimited, not coerced to the
// default 1 tok/s limiter.
func TestTokenLimiterZeroDimensionUnlimited(t *testing.T) {
	// Output disabled (0); input enforced.
	tl := NewTokenLimiter(1000, 1000, 0, 0)
	for i := 0; i < 50; i++ {
		if ok, dim, _ := tl.Allow("a", 1, 1_000_000); !ok {
			t.Fatalf("output should be unlimited, got dim=%q on iter %d", dim, i)
		}
	}
	if _, ok := tl.OutputStat("a"); ok {
		t.Error("OutputStat should report disabled when output is unlimited")
	}
	if _, ok := tl.InputStat("a"); !ok {
		t.Error("InputStat should report enabled when input is limited")
	}
	// Input still enforced (burst 1000).
	if ok, _, _ := tl.Allow("b", 1000, 0); !ok {
		t.Fatal("first input request within burst should pass")
	}
	if ok, dim, _ := tl.Allow("b", 1000, 0); ok || dim != "input_tokens" {
		t.Fatalf("input should still be enforced, got ok=%v dim=%q", ok, dim)
	}
}

// An output-limited request must NOT debit the input bucket (peek-then-consume),
// so repeated output rejections don't starve later input-bound requests.
func TestTokenLimiterNoCrossDimensionDrain(t *testing.T) {
	tl := NewTokenLimiter(0.01, 1000, 0.01, 100) // input burst 1000, output burst 100

	// First request consumes input=50, output=100 (drains output).
	if ok, _, _ := tl.Allow("a", 50, 100); !ok {
		t.Fatal("first request should pass")
	}
	// Five output-limited requests: each must be rejected on output WITHOUT
	// consuming input.
	for i := 0; i < 5; i++ {
		if ok, dim, _ := tl.Allow("a", 50, 100); ok || dim != "output_tokens" {
			t.Fatalf("iter %d: expected output_tokens rejection, got ok=%v dim=%q", i, ok, dim)
		}
	}
	// Input bucket should still hold ~950 (only the first request debited it).
	// With the old debit-then-check behavior it would have lost 50*6=300.
	if ok, dim, _ := tl.Allow("a", 900, 0); !ok {
		t.Fatalf("input should retain capacity after output rejections, got dim=%q", dim)
	}
}

func TestOutputAdmissionEstimatorBounds(t *testing.T) {
	if est := NewOutputAdmissionEstimator(OutputAdmissionEstimatorConfig{}); est != nil {
		t.Fatal("disabled estimator should be nil")
	}
	est := NewOutputAdmissionEstimator(OutputAdmissionEstimatorConfig{Enabled: true, Fraction: 0.25, Floor: 100, Ceiling: 500})
	if got, ok := est.Estimate(10); !ok || got != 10 {
		t.Fatalf("small max should cap floor at max_tokens, got %d ok=%v", got, ok)
	}
	if got, _ := est.Estimate(1000); got != 250 {
		t.Fatalf("fraction estimate = %d, want 250", got)
	}
	if got, _ := est.Estimate(10_000); got != 500 {
		t.Fatalf("ceiling estimate = %d, want 500", got)
	}
}

func TestTokenLimiterDebitOutputCreatesFutureDebt(t *testing.T) {
	tl := NewTokenLimiter(0, 0, 0.000001, 100)
	if ok, dim, _ := tl.Allow("acct", 0, 80); !ok {
		t.Fatalf("initial output charge should pass, got dim=%q", dim)
	}
	tl.DebitOutput("acct", 30)
	if ok, dim, _ := tl.Allow("acct", 0, 1); ok || dim != "output_tokens" {
		t.Fatalf("future debt should reject subsequent output, got ok=%v dim=%q", ok, dim)
	}
}

// Concurrent same-account requests must not over-admit past the bucket: with
// the per-account lock, exactly burst/charge requests succeed. Run with -race.
func TestTokenLimiterConcurrentNoOverAdmit(t *testing.T) {
	// Output burst 100, ~no refill; each request charges 10 → exactly 10 admit.
	tl := NewTokenLimiter(0, 0, 0.0001, 100)

	const goroutines = 100
	var wg sync.WaitGroup
	var admitted int64
	wg.Add(goroutines)
	for i := 0; i < goroutines; i++ {
		go func() {
			defer wg.Done()
			if ok, _, _ := tl.Allow("acct", 0, 10); ok {
				atomic.AddInt64(&admitted, 1)
			}
		}()
	}
	wg.Wait()

	if admitted != 10 {
		t.Fatalf("admitted = %d, want exactly 10 (burst 100 / charge 10) — over/under-admission means the peek+consume isn't atomic", admitted)
	}
}

func TestStat(t *testing.T) {
	l := New(Config{RPS: 60, Burst: 60}) // 3600/min
	st := l.Stat("fresh")
	if st.LimitPerMinute != 3600 {
		t.Errorf("LimitPerMinute = %d, want 3600", st.LimitPerMinute)
	}
	if st.Remaining != 60 {
		t.Errorf("fresh Remaining = %d, want 60 (full burst)", st.Remaining)
	}
	if st.ResetSeconds != 0 {
		t.Errorf("fresh ResetSeconds = %d, want 0", st.ResetSeconds)
	}

	// Consume 50; remaining should drop and reset should be > 0.
	l.AllowN("acct", 50)
	st = l.Stat("acct")
	if st.Remaining > 11 {
		t.Errorf("Remaining = %d, want ~10 after consuming 50/60", st.Remaining)
	}
	if st.ResetSeconds <= 0 {
		t.Errorf("ResetSeconds = %d, want > 0 after draining", st.ResetSeconds)
	}
}
