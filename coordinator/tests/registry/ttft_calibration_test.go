package registry_test

import (
	"fmt"
	"math"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/ttftcalibration"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func resetCalibrator(t *testing.T) {
	t.Helper()
	production.ResetTTFTCalibration()
	t.Cleanup(production.ResetTTFTCalibration)
}

// feedObservations feeds the actual process-wide scheduler/settlement owner.
func feedObservations(t *testing.T, model, chip string, n int, ratio float64) {
	t.Helper()
	for i := 0; i < n; i++ {
		id := fmt.Sprintf("%s-%s-obs-%d", model, chip, i)
		production.NoteTTFTPrediction(id, 0, model, chip, 1000)
		if _, ok := production.RecordTTFTObservation(id, 0, 1000*ratio); !ok {
			t.Fatalf("observation %d not recorded", i)
		}
	}
}

func feedCalibrator(t *testing.T, c *ttftcalibration.Calibrator, model, chip string, n int, ratio float64) {
	t.Helper()
	for i := 0; i < n; i++ {
		id := fmt.Sprintf("%s-%s-obs-%d", model, chip, i)
		c.NotePrediction(id, 0, model, chip, 1000)
		if _, ok := c.RecordActual(id, 0, 1000*ratio); !ok {
			t.Fatalf("observation %d not recorded", i)
		}
	}
}

func TestTTFTCalibratorWarmupUsesUnitRatio(t *testing.T) {
	c := ttftcalibration.New(nil, nil)
	model := "warmup-model"

	feedCalibrator(t, c, model, "M3", ttftcalibration.WarmupObs-1, 0.33)
	if got := c.LearnedRatio(model, "M3"); got != 1.0 {
		t.Fatalf("ratio below warm-up = %f, want 1.0", got)
	}

	feedCalibrator(t, c, model, "M3", 1, 0.33)
	got := c.LearnedRatio(model, "M3")
	if math.Abs(got-0.33) > 0.001 {
		t.Fatalf("ratio at warm-up = %f, want ~0.33", got)
	}
}

func TestTTFTCalibratorConvergesToTrueRatio(t *testing.T) {
	c := ttftcalibration.New(nil, nil)
	model := "converge-model"

	// Simulate the production gpt-oss bias: predictions 3x the actual.
	for i := 0; i < 2*ttftcalibration.WindowSize; i++ {
		id := fmt.Sprintf("converge-%d", i)
		predicted := 1500.0 + float64(i%7)*300.0
		c.NotePrediction(id, 0, model, "M4", predicted)
		c.RecordActual(id, 0, predicted/3.0)
	}
	got := c.LearnedRatio(model, "M4")
	if math.Abs(got-1.0/3.0) > 0.01 {
		t.Fatalf("converged ratio = %f, want ~0.333", got)
	}
}

func TestTTFTCalibratorClampsAppliedRatio(t *testing.T) {
	c := ttftcalibration.New(nil, nil)

	feedCalibrator(t, c, "clamp-low", "M3", ttftcalibration.WarmupObs, 0.05)
	if got := c.LearnedRatio("clamp-low", "M3"); got != ttftcalibration.RatioMin {
		t.Fatalf("low ratio = %f, want clamp floor %f", got, ttftcalibration.RatioMin)
	}

	feedCalibrator(t, c, "clamp-high", "M3", ttftcalibration.WarmupObs, 5.0)
	if got := c.LearnedRatio("clamp-high", "M3"); got != ttftcalibration.RatioMax {
		t.Fatalf("high ratio = %f, want clamp ceiling %f", got, ttftcalibration.RatioMax)
	}
}

func TestTTFTCalibratorOutlierBarelyMoves(t *testing.T) {
	c := ttftcalibration.New(nil, nil)
	model := "outlier-model"

	// 100 normal observations around 0.33, then one 30s cold-load actual
	// against a 1s prediction (ratio 30). The windowed median must not move.
	feedCalibrator(t, c, model, "M3", 100, 0.33)
	before := c.LearnedRatio(model, "M3")
	c.NotePrediction("outlier-req", 0, model, "M3", 1000)
	c.RecordActual("outlier-req", 0, 30_000)
	after := c.LearnedRatio(model, "M3")
	if math.Abs(after-before) > 0.01 {
		t.Fatalf("one outlier moved ratio %f -> %f (max drift 0.01)", before, after)
	}
}

func TestTTFTCalibratorKillSwitch(t *testing.T) {
	c := ttftcalibration.New(nil, nil)
	model := "killswitch-model"
	feedCalibrator(t, c, model, "M3", ttftcalibration.WarmupObs, 0.33)

	t.Setenv("EIGENINFERENCE_TTFT_CALIBRATION", "off")
	if got := c.AppliedRatio(model, "M3"); got != 1.0 {
		t.Fatalf("applied ratio with kill switch = %f, want 1.0", got)
	}
	// The learned ratio stays observable while off.
	if got := c.LearnedRatio(model, "M3"); math.Abs(got-0.33) > 0.001 {
		t.Fatalf("learned ratio with kill switch = %f, want ~0.33", got)
	}

	t.Setenv("EIGENINFERENCE_TTFT_CALIBRATION", "on")
	if got := c.AppliedRatio(model, "M3"); math.Abs(got-0.33) > 0.001 {
		t.Fatalf("applied ratio re-enabled = %f, want ~0.33", got)
	}
}

func TestTTFTCalibratorChipFamilyFallback(t *testing.T) {
	c := ttftcalibration.New(nil, nil)
	model := "chip-model"

	// An unseen chip family falls back to the model-level ratio.
	feedCalibrator(t, c, model, "M3", ttftcalibration.WarmupObs, 0.5)
	if got := c.LearnedRatio(model, "M9"); math.Abs(got-0.5) > 0.001 {
		t.Fatalf("unseen-chip fallback ratio = %f, want model-level 0.5", got)
	}

	// A warmed-up chip window wins over the mixed model aggregate.
	feedCalibrator(t, c, model, "M9", ttftcalibration.WarmupObs, 1.2)
	if got := c.LearnedRatio(model, "M9"); math.Abs(got-1.2) > 0.001 {
		t.Fatalf("chip-specific ratio = %f, want 1.2", got)
	}
	if got := c.LearnedRatio(model, "M3"); math.Abs(got-0.5) > 0.001 {
		t.Fatalf("original chip ratio = %f, want 0.5", got)
	}
}

func TestTTFTCalibratorUnmatchedObservationIgnored(t *testing.T) {
	c := ttftcalibration.New(nil, nil)
	if _, ok := c.RecordActual("never-predicted", 0, 500); ok {
		t.Fatal("observation without a pending prediction must be dropped")
	}
	// Attempt mismatch is a miss too: prediction for attempt 0, actual for 1.
	c.NotePrediction("req-a", 0, "m", "M3", 1000)
	if _, ok := c.RecordActual("req-a", 1, 500); ok {
		t.Fatal("attempt-mismatched observation must be dropped")
	}
	if _, ok := c.RecordActual("req-a", 0, 500); !ok {
		t.Fatal("matching observation must be recorded")
	}
}

func TestTTFTCalibratorExpiredPredictionDropped(t *testing.T) {
	pending := ttftcalibration.NewPendingPredictions(nil)
	c := ttftcalibration.New(pending, nil)
	pending.Put(ttftcalibration.PendingID{RequestID: "stale-req", Attempt: 0}, ttftcalibration.Prediction{
		Model: "m", Chip: "M3", RawMs: 1000,
		At: time.Now().Add(-ttftcalibration.PendingTTL - time.Minute),
	})
	if _, ok := c.RecordActual("stale-req", 0, 500); ok {
		t.Fatal("expired prediction must not produce an observation")
	}
}

func TestTTFTCalibratorPendingMapBounded(t *testing.T) {
	pending := ttftcalibration.NewPendingPredictions(nil)
	c := ttftcalibration.New(pending, nil)
	// Fill to capacity with expired entries; the next insert sweeps them.
	stale := time.Now().Add(-ttftcalibration.PendingTTL - time.Minute)
	for i := 0; i < ttftcalibration.MaxPending; i++ {
		pending.Put(ttftcalibration.PendingID{RequestID: fmt.Sprintf("old-%d", i)}, ttftcalibration.Prediction{Model: "m", RawMs: 1, At: stale})
	}
	c.NotePrediction("fresh", 0, "m", "M3", 1000)
	n := 0
	for i := 0; i < ttftcalibration.MaxPending; i++ {
		if _, ok := pending.Take(ttftcalibration.PendingID{RequestID: fmt.Sprintf("old-%d", i)}); ok {
			n++
		}
	}
	// RecordActual consumes the remaining known key through the real join.
	_, fresh := c.RecordActual("fresh", 0, 300)
	if fresh {
		n++
	}
	if n > ttftcalibration.MaxPending {
		t.Fatalf("pending map size %d exceeds cap %d", n, ttftcalibration.MaxPending)
	}
	if !fresh {
		t.Fatal("fresh prediction must survive the sweep")
	}
}

// Expired entries must be reaped well below the hard cap.
func TestTTFTCalibratorPendingSweepsBelowCap(t *testing.T) {
	schedule := &ttftcalibration.SweepSchedule{}
	pending := ttftcalibration.NewPendingPredictions(schedule)
	c := ttftcalibration.New(pending, nil)
	stale := time.Now().Add(-ttftcalibration.PendingTTL - time.Minute)
	for i := 0; i < ttftcalibration.SweepThreshold+10; i++ {
		pending.Put(ttftcalibration.PendingID{RequestID: fmt.Sprintf("old-%d", i)}, ttftcalibration.Prediction{Model: "m", RawMs: 1, At: stale})
	}
	schedule.Swept(time.Now().Add(-ttftcalibration.SweepInterval - time.Second))
	c.NotePrediction("fresh", 0, "m", "M3", 1000)
	n := 0
	for i := 0; i < ttftcalibration.SweepThreshold+10; i++ {
		if _, ok := pending.Take(ttftcalibration.PendingID{RequestID: fmt.Sprintf("old-%d", i)}); ok {
			n++
		}
	}
	if _, ok := pending.Take(ttftcalibration.PendingID{RequestID: "fresh"}); ok {
		n++
	}
	if n != 1 {
		t.Fatalf("TTL sweep above the threshold must reap expired entries: %d left, want 1", n)
	}
}

func TestCalibratedTTFTMsLeavesColdPenaltyUnscaled(t *testing.T) {
	c := ttftcalibration.New(nil, nil)
	model := "cold-scale-model"
	feedCalibrator(t, c, model, "M3", ttftcalibration.WarmupObs, 0.5)
	ratio := c.AppliedRatio(model, "M3")
	if got := ttftcalibration.Apply(3000, 0, ratio); math.Abs(got-1500) > 0.001 {
		t.Fatalf("warm calibrated = %f, want 1500", got)
	}

	const slotStatePenaltyUnknown = 30000.0
	want := slotStatePenaltyUnknown + 3000*0.5
	if got := ttftcalibration.Apply(slotStatePenaltyUnknown+3000, slotStatePenaltyUnknown, ratio); math.Abs(got-want) > 0.001 {
		t.Fatalf("cold calibrated = %f, want %f (penalty unscaled)", got, want)
	}
	if got := ttftcalibration.Apply(0, 0, ratio); got != 0 {
		t.Fatalf("zero estimate calibrated = %f, want 0", got)
	}
}

func TestTTFTCalibratorConcurrentAccess(t *testing.T) {
	c := ttftcalibration.New(nil, nil)
	model := "race-model"
	var wg sync.WaitGroup
	for g := 0; g < 8; g++ {
		wg.Add(1)
		go func(g int) {
			defer wg.Done()
			for i := 0; i < 200; i++ {
				id := fmt.Sprintf("race-%d-%d", g, i)
				c.NotePrediction(id, 0, model, "M3", 1000)
				c.RecordActual(id, 0, 400)
			}
		}(g)
	}
	for g := 0; g < 4; g++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 400; i++ {
				_ = c.AppliedRatio(model, "M3")
				_ = c.LearnedRatio(model, "")
				_ = ttftcalibration.Apply(2000, 0, c.AppliedRatio(model, "M3"))
			}
		}()
	}
	wg.Wait()
	if got := c.LearnedRatio(model, "M3"); math.Abs(got-0.4) > 0.001 {
		t.Fatalf("post-race ratio = %f, want 0.4", got)
	}
}
