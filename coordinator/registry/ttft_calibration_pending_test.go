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
