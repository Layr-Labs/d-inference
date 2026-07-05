package registry

import (
	"fmt"
	"math"
	"sync"
	"testing"
	"time"
)

func resetCalibrator(t *testing.T) {
	t.Helper()
	ResetTTFTCalibration()
	t.Cleanup(ResetTTFTCalibration)
}

// feedObservations pushes n prediction+actual pairs for (model, chip) with the
// given actual/predicted ratio through the real join path.
func feedObservations(t *testing.T, model, chip string, n int, ratio float64) {
	t.Helper()
	for i := 0; i < n; i++ {
		id := fmt.Sprintf("%s-%s-obs-%d", model, chip, i)
		ttftCalibration.notePrediction(id, 0, model, chip, 1000)
		if _, ok := ttftCalibration.recordActual(id, 0, 1000*ratio); !ok {
			t.Fatalf("observation %d not recorded", i)
		}
	}
}

func TestTTFTCalibratorWarmupUsesUnitRatio(t *testing.T) {
	resetCalibrator(t)
	model := "warmup-model"

	feedObservations(t, model, "M3", ttftCalibrationWarmupObs-1, 0.33)
	if got := TTFTCalibrationRatio(model, "M3"); got != 1.0 {
		t.Fatalf("ratio below warm-up = %f, want 1.0", got)
	}

	feedObservations(t, model, "M3", 1, 0.33)
	got := TTFTCalibrationRatio(model, "M3")
	if math.Abs(got-0.33) > 0.001 {
		t.Fatalf("ratio at warm-up = %f, want ~0.33", got)
	}
}

func TestTTFTCalibratorConvergesToTrueRatio(t *testing.T) {
	resetCalibrator(t)
	model := "converge-model"

	// Simulate the production gpt-oss bias: predictions 3x the actual.
	for i := 0; i < 2*ttftCalibrationWindowSize; i++ {
		id := fmt.Sprintf("converge-%d", i)
		predicted := 1500.0 + float64(i%7)*300.0
		ttftCalibration.notePrediction(id, 0, model, "M4", predicted)
		ttftCalibration.recordActual(id, 0, predicted/3.0)
	}
	got := TTFTCalibrationRatio(model, "M4")
	if math.Abs(got-1.0/3.0) > 0.01 {
		t.Fatalf("converged ratio = %f, want ~0.333", got)
	}
}

func TestTTFTCalibratorClampsAppliedRatio(t *testing.T) {
	resetCalibrator(t)

	feedObservations(t, "clamp-low", "M3", ttftCalibrationWarmupObs, 0.05)
	if got := TTFTCalibrationRatio("clamp-low", "M3"); got != ttftCalibrationRatioMin {
		t.Fatalf("low ratio = %f, want clamp floor %f", got, ttftCalibrationRatioMin)
	}

	feedObservations(t, "clamp-high", "M3", ttftCalibrationWarmupObs, 5.0)
	if got := TTFTCalibrationRatio("clamp-high", "M3"); got != ttftCalibrationRatioMax {
		t.Fatalf("high ratio = %f, want clamp ceiling %f", got, ttftCalibrationRatioMax)
	}
}

func TestTTFTCalibratorOutlierBarelyMoves(t *testing.T) {
	resetCalibrator(t)
	model := "outlier-model"

	// 100 normal observations around 0.33, then one 30s cold-load actual
	// against a 1s prediction (ratio 30). The windowed median must not move.
	feedObservations(t, model, "M3", 100, 0.33)
	before := TTFTCalibrationRatio(model, "M3")

	ttftCalibration.notePrediction("outlier-req", 0, model, "M3", 1000)
	ttftCalibration.recordActual("outlier-req", 0, 30_000)

	after := TTFTCalibrationRatio(model, "M3")
	if math.Abs(after-before) > 0.01 {
		t.Fatalf("one outlier moved ratio %f -> %f (max drift 0.01)", before, after)
	}
}

func TestTTFTCalibratorKillSwitch(t *testing.T) {
	resetCalibrator(t)
	model := "killswitch-model"
	feedObservations(t, model, "M3", ttftCalibrationWarmupObs, 0.33)

	t.Setenv("EIGENINFERENCE_TTFT_CALIBRATION", "off")
	if got := ttftCalibration.appliedRatio(model, "M3"); got != 1.0 {
		t.Fatalf("applied ratio with kill switch = %f, want 1.0", got)
	}
	// The learned ratio stays observable while off.
	if got := TTFTCalibrationRatio(model, "M3"); math.Abs(got-0.33) > 0.001 {
		t.Fatalf("learned ratio with kill switch = %f, want ~0.33", got)
	}

	t.Setenv("EIGENINFERENCE_TTFT_CALIBRATION", "on")
	if got := ttftCalibration.appliedRatio(model, "M3"); math.Abs(got-0.33) > 0.001 {
		t.Fatalf("applied ratio re-enabled = %f, want ~0.33", got)
	}
}

func TestTTFTCalibratorChipFamilyFallback(t *testing.T) {
	resetCalibrator(t)
	model := "chip-model"

	// Observations from M3 boxes feed both the chip window and the model
	// aggregate. An unseen chip family falls back to the model-level ratio.
	feedObservations(t, model, "M3", ttftCalibrationWarmupObs, 0.5)
	if got := TTFTCalibrationRatio(model, "M9"); math.Abs(got-0.5) > 0.001 {
		t.Fatalf("unseen-chip fallback ratio = %f, want model-level 0.5", got)
	}

	// Once the other chip has its own warmed-up window, it wins over the
	// (now mixed) model aggregate.
	feedObservations(t, model, "M9", ttftCalibrationWarmupObs, 1.2)
	if got := TTFTCalibrationRatio(model, "M9"); math.Abs(got-1.2) > 0.001 {
		t.Fatalf("chip-specific ratio = %f, want 1.2", got)
	}
	if got := TTFTCalibrationRatio(model, "M3"); math.Abs(got-0.5) > 0.001 {
		t.Fatalf("original chip ratio = %f, want 0.5", got)
	}
}

func TestTTFTCalibratorUnmatchedObservationIgnored(t *testing.T) {
	resetCalibrator(t)
	if _, ok := ttftCalibration.recordActual("never-predicted", 0, 500); ok {
		t.Fatal("observation without a pending prediction must be dropped")
	}
	// Attempt mismatch is a miss too: prediction for attempt 0, actual for 1.
	ttftCalibration.notePrediction("req-a", 0, "m", "M3", 1000)
	if _, ok := ttftCalibration.recordActual("req-a", 1, 500); ok {
		t.Fatal("attempt-mismatched observation must be dropped")
	}
	if _, ok := ttftCalibration.recordActual("req-a", 0, 500); !ok {
		t.Fatal("matching observation must be recorded")
	}
}

func TestTTFTCalibratorExpiredPredictionDropped(t *testing.T) {
	resetCalibrator(t)
	c := ttftCalibration
	c.mu.Lock()
	c.pending[ttftPendingKey("stale-req", 0)] = ttftPendingPrediction{
		model: "m", chip: "M3", rawMs: 1000,
		at: time.Now().Add(-ttftCalibrationPendingTTL - time.Minute),
	}
	c.mu.Unlock()
	if _, ok := c.recordActual("stale-req", 0, 500); ok {
		t.Fatal("expired prediction must not produce an observation")
	}
}

func TestTTFTCalibratorPendingMapBounded(t *testing.T) {
	resetCalibrator(t)
	c := ttftCalibration
	// Fill to capacity with expired entries; the next insert sweeps them.
	c.mu.Lock()
	stale := time.Now().Add(-ttftCalibrationPendingTTL - time.Minute)
	for i := 0; i < ttftCalibrationMaxPending; i++ {
		c.pending[ttftPendingKey(fmt.Sprintf("old-%d", i), 0)] = ttftPendingPrediction{model: "m", rawMs: 1, at: stale}
	}
	c.mu.Unlock()

	c.notePrediction("fresh", 0, "m", "M3", 1000)
	c.mu.RLock()
	n := len(c.pending)
	c.mu.RUnlock()
	if n > ttftCalibrationMaxPending {
		t.Fatalf("pending map size %d exceeds cap %d", n, ttftCalibrationMaxPending)
	}
	if _, ok := c.recordActual("fresh", 0, 300); !ok {
		t.Fatal("fresh prediction must survive the sweep")
	}
}

// Expired entries must be reaped by the opportunistic TTL sweep well below the
// hard cap — steady-state memory tracks live traffic instead of plateauing at
// ttftCalibrationMaxPending between capacity-triggered sweeps.
func TestTTFTCalibratorPendingSweepsBelowCap(t *testing.T) {
	resetCalibrator(t)
	c := ttftCalibration
	c.mu.Lock()
	stale := time.Now().Add(-ttftCalibrationPendingTTL - time.Minute)
	for i := 0; i < ttftCalibrationSweepThreshold+10; i++ {
		c.pending[ttftPendingKey(fmt.Sprintf("old-%d", i), 0)] = ttftPendingPrediction{model: "m", rawMs: 1, at: stale}
	}
	c.lastSweep = time.Now().Add(-ttftCalibrationSweepInterval - time.Second)
	c.mu.Unlock()

	c.notePrediction("fresh", 0, "m", "M3", 1000)
	c.mu.RLock()
	n := len(c.pending)
	c.mu.RUnlock()
	if n != 1 {
		t.Fatalf("TTL sweep above the threshold must reap expired entries: %d left, want 1", n)
	}
}

func TestCalibratedTTFTMsLeavesColdPenaltyUnscaled(t *testing.T) {
	resetCalibrator(t)
	model := "cold-scale-model"
	feedObservations(t, model, "M3", ttftCalibrationWarmupObs, 0.5)

	warm := routingSnapshot{model: model, chipFamily: "M3", slotState: "running"}
	if got := calibratedTTFTMs(warm, 3000); math.Abs(got-1500) > 0.001 {
		t.Fatalf("warm calibrated = %f, want 1500", got)
	}

	cold := routingSnapshot{model: model, chipFamily: "M3", slotState: "unknown"}
	want := slotStatePenaltyUnknown + 3000*0.5
	if got := calibratedTTFTMs(cold, slotStatePenaltyUnknown+3000); math.Abs(got-want) > 0.001 {
		t.Fatalf("cold calibrated = %f, want %f (penalty unscaled)", got, want)
	}

	if got := calibratedTTFTMs(warm, 0); got != 0 {
		t.Fatalf("zero estimate calibrated = %f, want 0", got)
	}
}

func TestTTFTCalibratorConcurrentAccess(t *testing.T) {
	resetCalibrator(t)
	model := "race-model"
	var wg sync.WaitGroup
	for g := 0; g < 8; g++ {
		wg.Add(1)
		go func(g int) {
			defer wg.Done()
			for i := 0; i < 200; i++ {
				id := fmt.Sprintf("race-%d-%d", g, i)
				ttftCalibration.notePrediction(id, 0, model, "M3", 1000)
				ttftCalibration.recordActual(id, 0, 400)
			}
		}(g)
	}
	for g := 0; g < 4; g++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 400; i++ {
				_ = ttftCalibration.appliedRatio(model, "M3")
				_ = TTFTCalibrationRatio(model, "")
				_ = calibratedTTFTMs(routingSnapshot{model: model, chipFamily: "M3", slotState: "running"}, 2000)
			}
		}()
	}
	wg.Wait()
	if got := TTFTCalibrationRatio(model, "M3"); math.Abs(got-0.4) > 0.001 {
		t.Fatalf("post-race ratio = %f, want 0.4", got)
	}
}
