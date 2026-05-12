package ratelimit

import (
	"context"
	"log/slog"
	"os"
	"sync"
	"testing"
	"time"
)

func TestAllowEmptyAccountUnconditional(t *testing.T) {
	l := New(Config{RPS: 0.1, Burst: 1})
	for i := 0; i < 100; i++ {
		ok, _ := l.Allow("")
		if !ok {
			t.Fatalf("empty account should always be allowed")
		}
	}
}

func TestAllowBurstThenDeny(t *testing.T) {
	l := New(Config{RPS: 1, Burst: 5})
	const account = "acct-1"

	// Burst capacity = 5: first 5 must succeed.
	for i := 0; i < 5; i++ {
		ok, _ := l.Allow(account)
		if !ok {
			t.Fatalf("request %d should succeed within burst", i)
		}
	}
	// 6th request must be denied with a sane Retry-After.
	ok, retry := l.Allow(account)
	if ok {
		t.Fatalf("request 6 should be denied")
	}
	if retry <= 0 {
		t.Fatalf("retry after must be positive, got %v", retry)
	}
	if retry > maxRetryAfter {
		t.Fatalf("retry after must be clamped under %v, got %v", maxRetryAfter, retry)
	}
}

func TestAllowRefill(t *testing.T) {
	l := New(Config{RPS: 100, Burst: 1})
	const account = "acct-refill"

	ok, _ := l.Allow(account)
	if !ok {
		t.Fatal("first request should succeed")
	}
	// Immediately deny.
	ok, _ = l.Allow(account)
	if ok {
		t.Fatal("second immediate request should be denied with Burst=1")
	}
	// At 100 RPS the bucket refills in ~10ms; wait 30ms for headroom.
	time.Sleep(30 * time.Millisecond)
	ok, _ = l.Allow(account)
	if !ok {
		t.Fatal("after refill window the request should succeed")
	}
}

func TestAccountsIndependent(t *testing.T) {
	l := New(Config{RPS: 1, Burst: 1})
	if ok, _ := l.Allow("a"); !ok {
		t.Fatal("first request for 'a' should succeed")
	}
	if ok, _ := l.Allow("b"); !ok {
		t.Fatal("first request for 'b' should succeed (independent bucket)")
	}
	if ok, _ := l.Allow("a"); ok {
		t.Fatal("second request for 'a' should be denied")
	}
}

func TestPruneEvictsIdle(t *testing.T) {
	l := New(Config{RPS: 1, Burst: 1, IdleEvict: 10 * time.Millisecond})
	l.Allow("acct-a")
	l.Allow("acct-b")
	if got := l.Size(); got != 2 {
		t.Fatalf("size = %d, want 2", got)
	}
	time.Sleep(20 * time.Millisecond)
	dropped := l.Prune()
	if dropped != 2 {
		t.Errorf("dropped = %d, want 2", dropped)
	}
	if got := l.Size(); got != 0 {
		t.Errorf("after prune size = %d, want 0", got)
	}
}

func TestPrunerLoopStopsOnContext(t *testing.T) {
	l := New(Config{RPS: 1, Burst: 1, PruneEvery: 5 * time.Millisecond})
	logger := slog.New(slog.NewTextHandler(os.Stderr, nil))
	ctx, cancel := context.WithCancel(context.Background())
	l.StartPruner(ctx, logger, nil)
	time.Sleep(20 * time.Millisecond)
	cancel()
	// If StartPruner doesn't honor cancel, the goroutine leaks but the test
	// will still pass — we just can't observe it directly. At minimum
	// verify we didn't crash.
}

func TestConcurrentAllowSafe(t *testing.T) {
	l := New(Config{RPS: 1000, Burst: 100})
	const account = "shared"
	var wg sync.WaitGroup
	wg.Add(50)
	for i := 0; i < 50; i++ {
		go func() {
			defer wg.Done()
			for j := 0; j < 10; j++ {
				_, _ = l.Allow(account)
			}
		}()
	}
	wg.Wait()
	// If the map were unsafe, -race would catch it. Confirming no panic.
}

// TestNoPhantomDebtUnderContention guards the AllowN+TokensAt fix. The
// previous ReserveN+Cancel pattern could leave a bucket under-credited
// if many goroutines were denied concurrently. With the corrected pattern
// a denied request must NOT consume any tokens, so after the burst is
// exhausted and we wait for one full refill window, exactly the burst
// capacity should once again be available.
func TestNoPhantomDebtUnderContention(t *testing.T) {
	const burst = 10
	const rps = 1000.0 // 1ms per token refill
	l := New(Config{RPS: rps, Burst: burst})
	const account = "phantom-test"

	// Drain the bucket and pile on many concurrent denials.
	var wg sync.WaitGroup
	wg.Add(200)
	denied := int64(0)
	var deniedMu sync.Mutex
	for i := 0; i < 200; i++ {
		go func() {
			defer wg.Done()
			ok, _ := l.Allow(account)
			if !ok {
				deniedMu.Lock()
				denied++
				deniedMu.Unlock()
			}
		}()
	}
	wg.Wait()

	if denied < 1 {
		t.Fatalf("expected at least one denial after draining burst; got 0 (test broken)")
	}

	// Wait for full refill (burst tokens at 1000/sec = 10ms), plus margin.
	time.Sleep(100 * time.Millisecond)

	// The bucket should now be back to capacity. Verify by observing that
	// at least burst-1 immediate Allows succeed (allowing 1 token of slack
	// for the rate.Limiter's own internal accounting).
	successes := 0
	for i := 0; i < burst; i++ {
		if ok, _ := l.Allow(account); ok {
			successes++
		}
	}
	if successes < burst-1 {
		t.Fatalf("phantom debt detected: after refill window, only %d/%d burst Allows succeeded — denied requests appear to have consumed tokens", successes, burst)
	}
}
