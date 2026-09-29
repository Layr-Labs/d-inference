package registry

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"strings"
	"testing"
	"time"
)

func TestFirstContentUsesExactPromptWithoutQualifiedProfile(t *testing.T) {
	now := time.Now()
	r, p, profile, pr := calibratedCandidateFixture(t, now)
	delete(reviewedDeadlinePerformanceProfiles, profile.ID)
	p.BackendCapacity.Slots[0].PerformanceProfile = nil
	pr.EstimatedPromptTokens, pr.FirstContentPromptTokens = 3000, 3500
	got := calibratedForecast(r, p, pr, now).firstContent
	if got.PromptTokens != 4000 || got.PredictionSource != "" || got.ConservativeMs != 5660 {
		t.Fatalf("legacy predictor ignored exact count or changed margin: %+v", got)
	}
	pr.PromptWork.ModelArtifactHash = strings.Repeat("e", 64)
	got = calibratedForecast(r, p, pr, now).firstContent
	if got.PromptTokens != 3000 || got.ConservativeMs != 5160 {
		t.Fatalf("foreign artifact prompt count trusted: %+v", got)
	}
}

func TestCalibratedPromptUncertaintyUsesUpperBoundAndCachePartition(t *testing.T) {
	now := time.Now()
	r, p, profile, pr := calibratedCandidateFixture(t, now)
	pr.PromptWork.Source, pr.PromptWork.CalibrationID = protocol.PromptWorkCalibrated, "reviewed-template-fixture"
	pr.PromptWork.UpperBoundTokens = 5000
	baseline := calibratedForecast(r, p, pr, now)
	if baseline.firstContent.PredictionSource != "qualified_calibration" || baseline.firstContent.PromptTokens != 4000 || baseline.firstContent.ConservativeMs < 4200 {
		t.Fatalf("uncertainty omitted: %+v", baseline.firstContent)
	}
	c := &routingCandidate{}
	r.fillRoutingSnapshotPLocked(&c.snapshot, p, pr.Model, now)
	c.firstContentCachedTokens, c.firstContentCacheWeight, c.firstContentCacheExpiresAt = 3000, 1, now.Add(time.Minute)
	c.firstContentRestoreMs = 75
	r.estimateFirstContent(c, pr, now)
	if c.firstContent.PredictionSource != "" {
		t.Fatal("cold qualification borrowed for cached workload")
	}
	cell := profile.DeadlineCalibration.Cells[0]
	cell.CacheState = "reused"
	profile.DeadlineCalibration.Cells = append(profile.DeadlineCalibration.Cells, cell)
	r.estimateFirstContent(c, pr, now)
	if c.firstContent.PredictionSource != "qualified_calibration" || c.firstContent.RestoreMs != 75 || c.firstContent.CachedTokens != 3000 || c.firstContent.ConservativeMs != 2638 {
		t.Fatalf("cache upperbound/restore charge wrong: %+v", c.firstContent)
	}
}

func TestCalibratedDecodeUsesExplicitObservation(t *testing.T) {
	now := time.Now()
	r, p, _, pr := calibratedCandidateFixture(t, now)
	before := calibratedForecast(r, p, pr, now).firstContent
	// Slot observed TPS can be a different EWMA; the explicitly aged slower
	// engine measurement must cap a reviewed static rate even if that EWMA rose.
	p.BackendCapacity.Slots[0].ObservedDecodeTPS = 1000
	m := p.firstContentMeasurements["model"]
	m.decodeRate = 50
	p.firstContentMeasurements["model"] = m
	after := calibratedForecast(r, p, pr, now).firstContent
	if after.ConservativeMs <= before.ConservativeMs || after.PredictionSource != "qualified_calibration" {
		t.Fatalf("explicit slower decode observation ignored: before=%+v after=%+v", before, after)
	}
}
