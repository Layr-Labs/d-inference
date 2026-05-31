package ratelimit

import (
	"testing"
)

func TestAllowNWithRatePerKeyCeiling(t *testing.T) {
	l := New(Config{RPS: DefaultRPS, Burst: DefaultBurst})

	// Key "a" gets a 2-burst ceiling; the 3rd immediate request is rejected.
	for i := 0; i < 2; i++ {
		if ok, _ := l.AllowNWithRate("a", 1, 0.01, 2); !ok {
			t.Fatalf("request %d unexpectedly rejected", i+1)
		}
	}
	if ok, retry := l.AllowNWithRate("a", 1, 0.01, 2); ok || retry <= 0 {
		t.Errorf("3rd request should be rejected with retry-after, ok=%v retry=%v", ok, retry)
	}

	// A different key has its own independent bucket.
	if ok, _ := l.AllowNWithRate("b", 1, 0.01, 2); !ok {
		t.Error("independent key should be allowed")
	}
}

func TestAllowNWithRateUnlimited(t *testing.T) {
	l := New(Config{})
	// Non-positive rate/burst means unlimited.
	for i := 0; i < 100; i++ {
		if ok, _ := l.AllowNWithRate("a", 1000, 0, 0); !ok {
			t.Fatalf("unlimited dimension rejected at %d", i)
		}
	}
}

func TestAllowNWithRateReconcilesRateChange(t *testing.T) {
	l := New(Config{})
	// Create the bucket at a generous burst.
	if ok, _ := l.AllowNWithRate("a", 1, 1, 10); !ok {
		t.Fatal("first request should pass")
	}
	// Lowering the per-key burst is reflected on the entry (reconciled), so a
	// request larger than the new burst is clamped to it rather than panicking
	// or using the stale rate. This just exercises the reconcile path.
	if ok, _ := l.AllowNWithRate("a", 100, 1, 2); !ok {
		// clamped to burst=2; with ~9 tokens left it still fits.
		t.Error("reconciled request should be admitted")
	}
}

func TestKeyTokenLimiterBothDimensions(t *testing.T) {
	tl := NewKeyTokenLimiter()

	// Input ceiling 100 (burst), output ceiling 50. Charge 80 in / 40 out.
	if ok, dim, _ := tl.Allow("k", 80, 40, 1, 100, 1, 50); !ok {
		t.Fatalf("first charge rejected on %s", dim)
	}
	// Next 80-input request exceeds the remaining input budget.
	if ok, dim, _ := tl.Allow("k", 80, 1, 1, 100, 1, 50); ok || dim != "input_tokens" {
		t.Errorf("expected input_tokens rejection, ok=%v dim=%q", ok, dim)
	}

	// A separate key is unaffected.
	if ok, _, _ := tl.Allow("other", 80, 40, 1, 100, 1, 50); !ok {
		t.Error("independent key should pass")
	}
}

func TestKeyTokenLimiterOutputRejectionDoesNotDebitInput(t *testing.T) {
	tl := NewKeyTokenLimiter()
	// Drain the output bucket (burst 100) with a full charge; input barely used.
	if ok, dim, _ := tl.Allow("k", 10, 100, 1, 1000, 1, 100); !ok {
		t.Fatalf("first charge rejected on %s", dim)
	}
	// Output now empty: the next request is rejected on output_tokens, and the
	// peek-before-consume guarantees input is NOT debited by that rejection.
	if ok, dim, _ := tl.Allow("k", 10, 100, 1, 1000, 1, 100); ok || dim != "output_tokens" {
		t.Fatalf("expected output rejection, ok=%v dim=%q", ok, dim)
	}
	// Input budget is intact: an input-only request (output unlimited) passes.
	if ok, _, _ := tl.Allow("k", 900, 0, 1, 1000, 0, 0); !ok {
		t.Error("input budget should not have been debited by the output rejection")
	}
}

func TestKeyTokenLimiterUnlimitedWhenNoRates(t *testing.T) {
	tl := NewKeyTokenLimiter()
	if ok, _, _ := tl.Allow("k", 999999, 999999, 0, 0, 0, 0); !ok {
		t.Error("no configured rates means unlimited")
	}
}

// TestPeekDoesNotConsume verifies that Peek leaves the bucket untouched, so a
// caller can peek multiple limiters and only commit when all pass — without
// draining a limiter whose sibling later rejects (Codex P2).
func TestPeekDoesNotConsume(t *testing.T) {
	tl := NewTokenLimiter(60, 100, 60, 100) // 100 input + 100 output burst

	// Many peeks must never reduce capacity.
	for i := 0; i < 50; i++ {
		if ok, _, _ := tl.Peek("acct", 100, 100); !ok {
			t.Fatalf("peek %d rejected though nothing was consumed", i)
		}
	}
	// A full charge still fits because no peek consumed anything.
	if ok, _, _ := tl.Peek("acct", 100, 100); !ok {
		t.Fatal("full charge should still fit after repeated peeks")
	}
	tl.Commit("acct", 100, 100)
	// Now the bucket is drained: the next peek is rejected.
	if ok, dim, _ := tl.Peek("acct", 100, 1); ok {
		t.Errorf("expected rejection after commit drained input, got ok (dim=%q)", dim)
	}
}

// TestKeyTokenPeekCommitNoDrainAcrossLimiters models the server's peek-both-then-
// commit: when the account limiter would reject, the per-key limiter must not be
// charged (its later peek must still pass).
func TestKeyTokenPeekCommitNoDrainAcrossLimiters(t *testing.T) {
	key := NewKeyTokenLimiter()
	acct := NewTokenLimiter(60, 100, 60, 100)

	// Exhaust the account input bucket so it will reject.
	acct.Commit("a", 100, 0)
	if ok, _, _ := acct.Peek("a", 100, 0); ok {
		t.Fatal("account bucket should be exhausted")
	}

	// Server logic: peek key (passes), peek account (fails) -> reject, commit
	// NEITHER. The key bucket must be untouched.
	if ok, _, _ := key.Peek("k", 50, 0, 60, 100, 0, 0); !ok {
		t.Fatal("per-key peek should pass")
	}
	if ok, _, _ := acct.Peek("a", 50, 0); ok {
		t.Fatal("account peek should fail (exhausted)")
	}
	// Because we did NOT commit the key, its full quota remains available.
	if ok, _, _ := key.Peek("k", 100, 0, 60, 100, 0, 0); !ok {
		t.Error("per-key quota must be intact after an account-side rejection (no drain)")
	}
}
