package registry_test

import (
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/forecast"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestFirstContentUsesExactPromptWithoutQualifiedProfile(t *testing.T) {
	now := time.Now()
	f := newCalibrationPolicyFixture(t, now)
	p, pr := f.provider, f.request
	p.BackendCapacity.Slots[0].DeadlineProfile = nil
	p.BackendCapacity.Slots[0].PerformanceProfile = nil
	pr.EstimatedPromptTokens, pr.FirstContentPromptTokens = 3000, 3500
	got := f.evaluate(pr, now).Estimate
	if got.PromptTokens != 4000 || got.PredictionSource != "" || got.ConservativeMs != 3330 {
		t.Fatalf("observed-rate predictor ignored exact count or delivery allowance: %+v", got)
	}
	pr.PromptWork.ModelArtifactHash = strings.Repeat("e", 64)
	got = f.evaluate(pr, now).Estimate
	if got.PromptTokens != 3000 || got.ConservativeMs != 3080 {
		t.Fatalf("foreign artifact prompt count trusted: %+v", got)
	}
}

func TestCalibratedPromptUncertaintyUsesUpperBoundAndCachePartition(t *testing.T) {
	now := time.Now()
	f := newCalibrationPolicyFixture(t, now)
	profile, pr := f.profile, f.request
	pr.PromptWork.Source, pr.PromptWork.CalibrationID = protocol.PromptWorkCalibrated, "reviewed-template-fixture"
	pr.PromptWork.UpperBoundTokens = 5000
	baseline := f.evaluate(pr, now).Estimate
	if baseline.PredictionSource != "qualified_calibration" || baseline.PromptTokens != 4000 || baseline.ConservativeMs < 4200 {
		t.Fatalf("uncertainty omitted: %+v", baseline)
	}
	benefit := forecast.CacheBenefit{Tokens: 3000, Weight: 1, ExpiresAt: now.Add(time.Minute), RestoreMS: 75}
	c := f.evaluate(pr, now, benefit).Estimate
	if c.PredictionSource != "" {
		t.Fatal("cold qualification borrowed for cached workload")
	}
	cell := profile.DeadlineCalibration.Cells[0]
	cell.CacheState = "reused"
	profile.DeadlineCalibration.Cells = append(profile.DeadlineCalibration.Cells, cell)
	c = f.evaluate(pr, now, benefit).Estimate
	if c.PredictionSource != "qualified_calibration" || c.RestoreMs != 75 || c.CachedTokens != 3000 || c.ConservativeMs != 2638 {
		t.Fatalf("cache upperbound/restore charge wrong: %+v", c)
	}
}

func TestCalibratedDecodeUsesExplicitObservation(t *testing.T) {
	now := time.Now()
	f := newCalibrationPolicyFixture(t, now)
	p, pr := f.provider, f.request
	before := f.evaluate(pr, now).Estimate
	// The explicit aged engine measurement caps the faster slot EWMA.
	p.BackendCapacity.Slots[0].ObservedDecodeTPS = 1000
	decode := p.BackendCapacity.Slots[0].PerformanceMeasurements.Decode
	decode.TokensPerSecond = 50
	decode.SampleCount++
	f.history.Reconcile(p.BackendCapacity, p.CapacityAcceptedAt, now, time.Second)
	after := f.evaluate(pr, now).Estimate
	if after.ConservativeMs <= before.ConservativeMs || after.PredictionSource != "qualified_calibration" {
		t.Fatalf("explicit slower decode observation ignored: before=%+v after=%+v", before, after)
	}
}
