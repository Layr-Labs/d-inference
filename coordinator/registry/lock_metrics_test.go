package registry

import (
	"sync"
	"testing"
	"time"
)

// TestRegistryMutexRecordsWriterWait pins the instrument: N writers parked
// behind a held reader are counted exactly once each, the recorded maximum
// covers the park, the pending-writer gauge returns to zero, and the snapshot
// resets while the peek does not.
func TestRegistryMutexRecordsWriterWait(t *testing.T) {
	reg := New(testLogger())
	const writers = 8
	const park = 30 * time.Millisecond

	reg.mu.RLock()
	var wg sync.WaitGroup
	for range writers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			reg.mu.Lock()
			reg.mu.Unlock()
		}()
	}
	// Every writer must be parked before the reader releases, otherwise a
	// fast writer could slip through before the park and record ~0 wait.
	deadline := time.Now().Add(2 * time.Second)
	for reg.mu.writersWaiting.Load() != writers {
		if time.Now().After(deadline) {
			reg.mu.RUnlock()
			t.Fatalf("writers parked = %d, want %d", reg.mu.writersWaiting.Load(), writers)
		}
		time.Sleep(time.Millisecond)
	}
	if got := reg.LockWaitPeek().WritersWaiting; got != writers {
		reg.mu.RUnlock()
		t.Fatalf("peek WritersWaiting = %d, want %d while parked", got, writers)
	}
	time.Sleep(park)
	reg.mu.RUnlock()
	wg.Wait()

	stats := reg.LockWaitSnapshot()
	if stats.Count != writers {
		t.Fatalf("Count = %d, want %d (every Lock counted exactly once, no sampling)", stats.Count, writers)
	}
	if stats.MaxUS < park.Microseconds() {
		t.Fatalf("MaxUS = %d, want >= park %d", stats.MaxUS, park.Microseconds())
	}
	if stats.MeanUS <= 0 || stats.P50US <= 0 || stats.P99US < stats.P50US || stats.P99US > stats.MaxUS {
		t.Fatalf("percentiles inconsistent: %+v", stats)
	}
	if stats.WritersWaiting != 0 {
		t.Fatalf("WritersWaiting = %d after all writers released, want 0", stats.WritersWaiting)
	}
	// Returns-and-resets: the next window starts empty.
	if again := reg.LockWaitSnapshot(); again.Count != 0 || again.MaxUS != 0 {
		t.Fatalf("second snapshot not reset: %+v", again)
	}
	// Peek accumulates without resetting.
	reg.mu.Lock()
	reg.mu.Unlock()
	if p1, p2 := reg.LockWaitPeek(), reg.LockWaitPeek(); p1.Count != 1 || p2.Count != 1 {
		t.Fatalf("peek counts = %d/%d, want 1/1 (non-resetting)", p1.Count, p2.Count)
	}
}

// TestLockWaitBuckets pins the log2 bucket layout and its percentile
// estimate: bucket i holds waits in [2^(i-1), 2^i) µs and the estimate reports
// the bucket's upper bound clamped to the exact maximum.
func TestLockWaitBuckets(t *testing.T) {
	cases := map[int64]int{0: 0, 1: 1, 2: 2, 3: 2, 4: 3, 7: 3, 8: 4, 1023: 10, 1024: 11, 1 << 40: lockWaitBuckets - 1}
	for us, want := range cases {
		if got := lockWaitBucket(us); got != want {
			t.Fatalf("lockWaitBucket(%d) = %d, want %d", us, got, want)
		}
	}
	if lockWaitBucketUpperUS(0) != 0 || lockWaitBucketUpperUS(1) != 2 || lockWaitBucketUpperUS(10) != 1024 {
		t.Fatalf("bucket upper bounds wrong: %d %d %d", lockWaitBucketUpperUS(0), lockWaitBucketUpperUS(1), lockWaitBucketUpperUS(10))
	}

	var m registryMutex
	// 90 short waits (~5 µs bucket 3) and 10 long waits (~3 ms bucket 12).
	for range 90 {
		m.recordWait(5 * time.Microsecond)
	}
	for range 10 {
		m.recordWait(3 * time.Millisecond)
	}
	stats := m.stats(false)
	if stats.Count != 100 || stats.MaxUS != 3000 {
		t.Fatalf("stats = %+v, want Count 100 MaxUS 3000", stats)
	}
	if stats.P50US != 8 {
		t.Fatalf("P50US = %d, want 8 (upper bound of the 5 µs bucket)", stats.P50US)
	}
	if stats.P95US != 3000 || stats.P99US != 3000 {
		t.Fatalf("P95/P99 = %d/%d, want 3000 (bucket upper bound 4096 clamped to the exact max)", stats.P95US, stats.P99US)
	}
	if stats.MeanUS != (90*5+10*3000)/100 {
		t.Fatalf("MeanUS = %d, want %d", stats.MeanUS, (90*5+10*3000)/100)
	}
}
