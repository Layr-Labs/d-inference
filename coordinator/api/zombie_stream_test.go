package api

import (
	"testing"
	"time"
)

func TestZombieStreamCancellerThrottle(t *testing.T) {
	z := newZombieStreamCanceller()
	t0 := time.Now()

	if !z.shouldCancel("req-1", t0) {
		t.Fatal("first chunk for an unknown request should cancel")
	}
	if z.shouldCancel("req-1", t0.Add(time.Second)) {
		t.Fatal("second chunk within the throttle window should NOT re-cancel")
	}
	// A different request is independent.
	if !z.shouldCancel("req-2", t0.Add(time.Second)) {
		t.Fatal("a different unknown request should cancel")
	}
	// After the throttle window, the same request cancels again.
	if !z.shouldCancel("req-1", t0.Add(zombieCancelThrottle+time.Second)) {
		t.Fatal("after the throttle window the same request should cancel again")
	}
}

func TestZombieStreamCancellerSweepBounded(t *testing.T) {
	z := newZombieStreamCanceller()
	base := time.Now()
	for i := 0; i < 5000; i++ {
		z.shouldCancel(string(rune('a'+i%26))+string(rune('0'+i%10))+string(rune(i)), base)
	}
	z.mu.Lock()
	n := len(z.sent)
	z.mu.Unlock()
	if n > zombieCancelMaxEntries {
		t.Fatalf("map not bounded during fresh burst: %d entries", n)
	}

	// All those are expired relative to a far-future call, which triggers the sweep.
	z.shouldCancel("trigger", base.Add(zombieCancelThrottle+time.Hour))
	z.mu.Lock()
	n = len(z.sent)
	z.mu.Unlock()
	if n > zombieCancelMaxEntries {
		t.Fatalf("map not bounded after sweep: %d entries", n)
	}
}
