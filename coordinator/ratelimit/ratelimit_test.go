package ratelimit

import (
	"context"
	"sync"
	"testing"
	"time"
)

func useFixedClock(l *Limiter) func(time.Duration) {
	now := time.Unix(1_700_000_000, 0)
	l.now = func() time.Time { return now }
	return func(elapsed time.Duration) { now = now.Add(elapsed) }
}

func TestAllowEmptyAccountUnconditional(t *testing.T) {
	l := New(Config{RPS: 0.1, Burst: 1})
	for range 100 {
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
	advance := useFixedClock(l)
	const account = "acct-refill"

	if ok, _ := l.Allow(account); !ok {
		t.Fatal("first request should succeed")
	}
	if ok, _ := l.Allow(account); ok {
		t.Fatal("second immediate request should be denied with Burst=1")
	}
	advance(10 * time.Millisecond)
	if ok, _ := l.Allow(account); !ok {
		t.Fatal("request should succeed after one token refill interval")
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
	advance := useFixedClock(l)
	l.Allow("acct-a")
	l.Allow("acct-b")
	if got := l.Size(); got != 2 {
		t.Fatalf("size = %d, want 2", got)
	}
	advance(10*time.Millisecond + time.Nanosecond)
	if dropped := l.Prune(); dropped != 2 {
		t.Errorf("dropped = %d, want 2", dropped)
	}
	if got := l.Size(); got != 0 {
		t.Errorf("after prune size = %d, want 0", got)
	}
}

func TestPrunerLoopStopsOnContext(t *testing.T) {
	l := New(Config{RPS: 1, Burst: 1, PruneEvery: time.Hour})
	ctx, cancel := context.WithCancel(context.Background())
	done := l.StartPruner(ctx, nil, nil)
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("pruner did not stop after context cancellation")
	}
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

// TestNoPhantomDebtUnderContention guards the AllowN+TokensAt fix. Denied
// requests must not consume tokens, so advancing a fixed clock by one full
// refill interval restores exactly the configured burst.
func TestNoPhantomDebtUnderContention(t *testing.T) {
	const burst = 10
	const rps = 1000.0
	l := New(Config{RPS: rps, Burst: burst})
	advance := useFixedClock(l)
	const account = "phantom-test"

	var wg sync.WaitGroup
	wg.Add(200)
	denied := int64(0)
	var deniedMu sync.Mutex
	for range 200 {
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
		t.Fatal("expected at least one denial after draining burst")
	}

	advance(time.Duration(float64(burst)/rps*float64(time.Second)))
	successes := 0
	for range burst {
		if ok, _ := l.Allow(account); ok {
			successes++
		}
	}
	if successes != burst {
		t.Fatalf("phantom debt detected: after refill only %d/%d requests succeeded", successes, burst)
	}
}
