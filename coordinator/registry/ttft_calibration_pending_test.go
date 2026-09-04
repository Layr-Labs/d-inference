package registry

import (
	"fmt"
	"testing"
	"time"
)

// TestTTFTCalibratorAtCapacityEvictsOneWithoutSweeping pins the bounded-work
// contract for a full pending map between sweeps: one reservation evicts
// exactly one entry (the map stays at the cap), records the new prediction,
// and does NOT run the whole-map TTL sweep (lastSweep is untouched).
func TestTTFTCalibratorAtCapacityEvictsOneWithoutSweeping(t *testing.T) {
	resetCalibrator(t)
	c := ttftCalibration
	c.mu.Lock()
	fresh := time.Now()
	for i := 0; i < ttftCalibrationMaxPending; i++ {
		c.pending[ttftPendingKey(fmt.Sprintf("live-%d", i), 0)] = ttftPendingPrediction{model: "m", rawMs: 1, at: fresh}
	}
	c.lastSweep = fresh
	c.mu.Unlock()

	c.notePrediction("new", 0, "m", "M3", 1000)

	c.mu.RLock()
	n := len(c.pending)
	swept := !c.lastSweep.Equal(fresh)
	_, present := c.pending[ttftPendingKey("new", 0)]
	c.mu.RUnlock()
	if n != ttftCalibrationMaxPending {
		t.Fatalf("pending map size %d, want exactly the cap %d", n, ttftCalibrationMaxPending)
	}
	if swept {
		t.Fatal("a full map with a recent sweep must not re-walk the whole map")
	}
	if !present {
		t.Fatal("the new prediction must be recorded")
	}
}

// TestTTFTCalibratorAtCapacityExpiredGoesFirst is the coordinator's case:
// 8,191 live + 1 expired at capacity. With the capacity sweep due (last sweep
// older than ttftCalibrationCapacitySweepInterval) the expired entry is the
// one reclaimed, every live entry survives, and the new prediction lands.
func TestTTFTCalibratorAtCapacityExpiredGoesFirst(t *testing.T) {
	resetCalibrator(t)
	c := ttftCalibration
	c.mu.Lock()
	now := time.Now()
	for i := 0; i < ttftCalibrationMaxPending-1; i++ {
		c.pending[ttftPendingKey(fmt.Sprintf("live-%d", i), 0)] = ttftPendingPrediction{model: "m", rawMs: 1, at: now}
	}
	c.pending[ttftPendingKey("expired", 0)] = ttftPendingPrediction{
		model: "m", rawMs: 1, at: now.Add(-ttftCalibrationPendingTTL - time.Minute)}
	c.lastSweep = now.Add(-ttftCalibrationCapacitySweepInterval - time.Second)
	c.mu.Unlock()

	c.notePrediction("new", 0, "m", "M3", 1000)

	c.mu.RLock()
	defer c.mu.RUnlock()
	if _, alive := c.pending[ttftPendingKey("expired", 0)]; alive {
		t.Fatal("expired entry must be reclaimed before any live one")
	}
	if _, present := c.pending[ttftPendingKey("new", 0)]; !present {
		t.Fatal("new prediction must be recorded")
	}
	for i := 0; i < ttftCalibrationMaxPending-1; i++ {
		if _, ok := c.pending[ttftPendingKey(fmt.Sprintf("live-%d", i), 0)]; !ok {
			t.Fatalf("live entry %d was evicted while an expired one existed", i)
		}
	}
	if len(c.pending) != ttftCalibrationMaxPending {
		t.Fatalf("pending size %d, want %d", len(c.pending), ttftCalibrationMaxPending)
	}
}

// TestTTFTCalibratorEvictProbePrefersExpired pins the between-sweeps probe:
// with expired entries dominating a full map, the bounded probe (≤ 8 entries,
// so it always sees at least one expired entry when only one is live) deletes
// an expired entry and never the live one — deterministic regardless of map
// iteration order.
func TestTTFTCalibratorEvictProbePrefersExpired(t *testing.T) {
	resetCalibrator(t)
	c := ttftCalibration
	c.mu.Lock()
	now := time.Now()
	stale := now.Add(-ttftCalibrationPendingTTL - time.Minute)
	for i := 0; i < ttftCalibrationMaxPending-1; i++ {
		c.pending[ttftPendingKey(fmt.Sprintf("old-%d", i), 0)] = ttftPendingPrediction{model: "m", rawMs: 1, at: stale}
	}
	c.pending[ttftPendingKey("live", 0)] = ttftPendingPrediction{model: "m", rawMs: 1, at: now}
	c.lastSweep = now // no sweep is due on either interval
	c.mu.Unlock()

	for i := 0; i < 64; i++ {
		c.notePrediction("new", i, "m", "M3", 1000)
	}

	c.mu.RLock()
	defer c.mu.RUnlock()
	if _, ok := c.pending[ttftPendingKey("live", 0)]; !ok {
		t.Fatal("probe evicted the live entry while expired ones remained")
	}
	if !c.lastSweep.Equal(now) {
		t.Fatal("probe path must not run the whole-map sweep")
	}
	if len(c.pending) != ttftCalibrationMaxPending {
		t.Fatalf("pending size %d, want the cap %d", len(c.pending), ttftCalibrationMaxPending)
	}
	for i := 0; i < 64; i++ {
		if _, ok := c.pending[ttftPendingKey("new", i)]; !ok {
			t.Fatalf("new prediction %d missing", i)
		}
	}
}

// TestTTFTCalibratorPendingKeyCannotAlias pins the struct key: request ids
// containing the former '#' delimiter can no longer collide across attempts.
func TestTTFTCalibratorPendingKeyCannotAlias(t *testing.T) {
	resetCalibrator(t)
	c := ttftCalibration
	c.notePrediction("req#1", 0, "m", "M3", 1000)
	c.notePrediction("req", 10, "m", "M3", 2000)
	c.mu.RLock()
	n := len(c.pending)
	c.mu.RUnlock()
	if n != 2 {
		t.Fatalf("pending entries = %d, want 2 distinct keys", n)
	}
}

// BenchmarkTTFTCalibratorNotePredictionAtCapacity is the reserve-storm shape:
// every reservation records a prediction none of which is ever resolved.
func BenchmarkTTFTCalibratorNotePredictionAtCapacity(b *testing.B) {
	c := newTTFTCalibrator()
	now := time.Now()
	for i := 0; i < ttftCalibrationMaxPending; i++ {
		c.pending[ttftPendingKey(fmt.Sprintf("live-%d", i), 0)] = ttftPendingPrediction{model: "m", rawMs: 1, at: now}
	}
	c.lastSweep = now
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		c.notePrediction("req", i, "m", "M3", 1000)
	}
}
