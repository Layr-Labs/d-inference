package registry_test

import (
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/ttftcalibration"
)

// One reservation at capacity between sweeps evicts exactly one entry and
// records its new prediction without touching the whole-map sweep schedule.
func TestTTFTCalibratorAtCapacityEvictsOneWithoutSweeping(t *testing.T) {
	schedule := &ttftcalibration.SweepSchedule{}
	pending := ttftcalibration.NewPendingPredictions(schedule)
	c := ttftcalibration.New(pending, nil)
	fresh := time.Now()
	for i := 0; i < ttftcalibration.MaxPending; i++ {
		pending.Put(ttftcalibration.PendingID{RequestID: fmt.Sprintf("live-%d", i)}, ttftcalibration.Prediction{Model: "m", RawMs: 1, At: fresh})
	}
	schedule.Swept(fresh)
	before := *schedule
	c.NotePrediction("new", 0, "m", "M3", 1000)
	n := 0
	for i := 0; i < ttftcalibration.MaxPending; i++ {
		if _, ok := pending.Take(ttftcalibration.PendingID{RequestID: fmt.Sprintf("live-%d", i)}); ok {
			n++
		}
	}
	_, present := pending.Take(ttftcalibration.PendingID{RequestID: "new"})
	if present {
		n++
	}
	swept := *schedule != before
	if n != ttftcalibration.MaxPending {
		t.Fatalf("pending map size %d, want exactly the cap %d", n, ttftcalibration.MaxPending)
	}
	if swept {
		t.Fatal("a full map with a recent sweep must not re-walk the whole map")
	}
	if !present {
		t.Fatal("the new prediction must be recorded")
	}
	checkCalibrationResetOwnership(t)
}

// With 8,191 live and one expired entry, the due capacity sweep must reclaim
// only the expired entry and preserve every live entry plus the new prediction.
func TestTTFTCalibratorAtCapacityExpiredGoesFirst(t *testing.T) {
	schedule := &ttftcalibration.SweepSchedule{}
	pending := ttftcalibration.NewPendingPredictions(schedule)
	c := ttftcalibration.New(pending, nil)
	now := time.Now()
	for i := 0; i < ttftcalibration.MaxPending-1; i++ {
		pending.Put(ttftcalibration.PendingID{RequestID: fmt.Sprintf("live-%d", i)}, ttftcalibration.Prediction{Model: "m", RawMs: 1, At: now})
	}
	pending.Put(ttftcalibration.PendingID{RequestID: "expired"}, ttftcalibration.Prediction{
		Model: "m", RawMs: 1, At: now.Add(-ttftcalibration.PendingTTL - time.Minute)})
	schedule.Swept(now.Add(-ttftcalibration.CapacitySweepInterval - time.Second))
	c.NotePrediction("new", 0, "m", "M3", 1000)
	n := 0
	if _, alive := pending.Take(ttftcalibration.PendingID{RequestID: "expired"}); alive {
		t.Fatal("expired entry must be reclaimed before any live one")
	}
	if _, present := pending.Take(ttftcalibration.PendingID{RequestID: "new"}); !present {
		t.Fatal("new prediction must be recorded")
	} else {
		n++
	}
	for i := 0; i < ttftcalibration.MaxPending-1; i++ {
		if _, ok := pending.Take(ttftcalibration.PendingID{RequestID: fmt.Sprintf("live-%d", i)}); !ok {
			t.Fatalf("live entry %d was evicted while an expired one existed", i)
		} else {
			n++
		}
	}
	if n != ttftcalibration.MaxPending {
		t.Fatalf("pending size %d, want %d", n, ttftcalibration.MaxPending)
	}
}

// Between sweeps, expired entries dominate the full map. The bounded probe
// must not evict the live entry or any of the 64 new predictions.
func TestTTFTCalibratorEvictProbePrefersExpired(t *testing.T) {
	schedule := &ttftcalibration.SweepSchedule{}
	pending := ttftcalibration.NewPendingPredictions(schedule)
	c := ttftcalibration.New(pending, nil)
	now := time.Now()
	stale := now.Add(-ttftcalibration.PendingTTL - time.Minute)
	for i := 0; i < ttftcalibration.MaxPending-1; i++ {
		pending.Put(ttftcalibration.PendingID{RequestID: fmt.Sprintf("old-%d", i)}, ttftcalibration.Prediction{Model: "m", RawMs: 1, At: stale})
	}
	pending.Put(ttftcalibration.PendingID{RequestID: "live"}, ttftcalibration.Prediction{Model: "m", RawMs: 1, At: now})
	schedule.Swept(now)
	before := *schedule
	for i := 0; i < 64; i++ {
		c.NotePrediction("new", i, "m", "M3", 1000)
	}
	n := 0
	if _, ok := pending.Take(ttftcalibration.PendingID{RequestID: "live"}); !ok {
		t.Fatal("probe evicted the live entry while expired ones remained")
	} else {
		n++
	}
	if *schedule != before {
		t.Fatal("probe path must not run the whole-map sweep")
	}
	for i := 0; i < ttftcalibration.MaxPending-1; i++ {
		if _, ok := pending.Take(ttftcalibration.PendingID{RequestID: fmt.Sprintf("old-%d", i)}); ok {
			n++
		}
	}
	for i := 0; i < 64; i++ {
		if _, ok := pending.Take(ttftcalibration.PendingID{RequestID: "new", Attempt: i}); !ok {
			t.Fatalf("new prediction %d missing", i)
		} else {
			n++
		}
	}
	if n != ttftcalibration.MaxPending {
		t.Fatalf("pending size %d, want the cap %d", n, ttftcalibration.MaxPending)
	}
}

// Request IDs containing the former delimiter cannot alias across attempts.
func TestTTFTCalibratorPendingKeyCannotAlias(t *testing.T) {
	pending := ttftcalibration.NewPendingPredictions(nil)
	c := ttftcalibration.New(pending, nil)
	c.NotePrediction("req#1", 0, "m", "M3", 1000)
	c.NotePrediction("req", 10, "m", "M3", 2000)
	n := 0
	for _, key := range []ttftcalibration.PendingID{{RequestID: "req#1", Attempt: 0}, {RequestID: "req", Attempt: 10}} {
		if _, ok := pending.Take(key); ok {
			n++
		}
	}
	if n != 2 {
		t.Fatalf("pending entries = %d, want 2 distinct keys", n)
	}
	checkCalibrationClockOrdering(t)
}

// BenchmarkTTFTCalibratorNotePredictionAtCapacity is the reserve-storm shape:
// every reservation records a prediction none of which is ever resolved.
func BenchmarkTTFTCalibratorNotePredictionAtCapacity(b *testing.B) {
	schedule := &ttftcalibration.SweepSchedule{}
	pending := ttftcalibration.NewPendingPredictions(schedule)
	c := ttftcalibration.New(pending, nil)
	now := time.Now()
	for i := 0; i < ttftcalibration.MaxPending; i++ {
		pending.Put(ttftcalibration.PendingID{RequestID: fmt.Sprintf("live-%d", i)}, ttftcalibration.Prediction{Model: "m", RawMs: 1, At: now})
	}
	schedule.Swept(now)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		c.NotePrediction("req", i, "m", "M3", 1000)
	}
}

func checkCalibrationClockOrdering(t *testing.T) {
	t.Helper()
	pending := ttftcalibration.NewPendingPredictions(nil)
	now := time.Unix(1_700_000_000, 0)
	key := ttftcalibration.PendingID{RequestID: "clock", Attempt: 0}
	var c *ttftcalibration.Calibrator
	calls := 0
	c = ttftcalibration.New(pending, func() time.Time {
		calls++
		switch calls {
		case 1:
			// Note samples time before taking the lock; a read must not deadlock.
			_ = c.LearnedRatio("m", "M3")
			return now
		case 2:
			// Actual samples time only after consuming the pending prediction.
			if _, ok := pending.Take(key); ok {
				t.Fatal("actual sampled time before taking its pending prediction")
			}
			return now.Add(ttftcalibration.PendingTTL)
		default:
			t.Fatalf("unexpected clock sample %d", calls)
			return now
		}
	})
	c.NotePrediction("clock", 0, "m", "M3", 1000)
	if _, ok := c.RecordActual("clock", 0, 500); !ok {
		t.Fatal("prediction must remain valid at the exact TTL boundary")
	}
	if _, ok := c.RecordActual("clock", 0, 500); ok {
		t.Fatal("consumed prediction must not be observed twice")
	}
	if calls != 2 {
		t.Fatalf("clock samples = %d, want 2", calls)
	}
}

func checkCalibrationResetOwnership(t *testing.T) {
	t.Helper()
	schedule := &ttftcalibration.SweepSchedule{}
	now := time.Unix(1_700_000_000, 0)
	schedule.Swept(now)
	before := *schedule
	pending := ttftcalibration.NewPendingPredictions(schedule)
	c := ttftcalibration.New(pending, func() time.Time { return now })
	c.NotePrediction("before-reset", 0, "m", "M3", 1000)
	c.Reset()
	if _, ok := pending.Take(ttftcalibration.PendingID{RequestID: "before-reset"}); ok {
		t.Fatal("reset must clear the retained pending owner")
	}
	if *schedule != before {
		t.Fatal("reset must preserve the sweep schedule")
	}
	c.NotePrediction("after-reset", 0, "m", "M3", 1000)
	if _, ok := pending.Take(ttftcalibration.PendingID{RequestID: "after-reset"}); !ok {
		t.Fatal("reset must not replace the retained pending owner")
	}
}
