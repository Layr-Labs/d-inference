package ratelimit

import (
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
