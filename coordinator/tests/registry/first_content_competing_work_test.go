package registry_test

import (
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/capacityvalue"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/deadline"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/forecast"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/performance"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestCalibratedFirstContentRequiresExactCompetingProfile(t *testing.T) {
	now := time.Now()
	var other deadline.Profile
	f := newCalibrationPolicyFixture(t, now, func(profile *deadline.Profile) []*deadline.Profile {
		other = *profile
		other.ID, other.ModelID, other.ArtifactSHA256 = "test-only-other", "other", strings.Repeat("f", 64)
		return []*deadline.Profile{&other}
	})
	r, p, profile, pr := f.registry, f.provider, f.profile, f.request
	r.MergeProviderModels(p.ID, []protocol.ModelInfo{{ID: other.ModelID, WeightHash: other.ArtifactSHA256}})
	var slot protocol.BackendSlotCapacity
	capacityvalue.CloneBackendSlot(&slot, &p.BackendCapacity.Slots[0])
	slot.Model, slot.State, slot.NumRunning = other.ModelID, "running", 1
	slot.DeadlineProfile.ID = other.ID
	slot.DeadlineWork = &protocol.DeadlineWork{Version: 1, Epoch: "epoch", Known: true, PrefillTokens: 1000, DecodeTokens: 100, RequestCount: 1, ContextTokensMax: 1100, ServiceFraction: .0625}
	p.BackendCapacity.Slots = append(p.BackendCapacity.Slots, slot)
	*p.BackendCapacity.WholeMacServiceUsed = .0625
	cell := profile.DeadlineCalibration.Cells[0]
	cell.Contention, cell.CompetitorProfileIDs = "other_model", []string{other.ID}
	cell.MaxActiveRequests, cell.MaxOtherModelRequests, cell.MaxOtherModelServiceFraction = 2, 1, .0625
	profile.DeadlineCalibration.Cells = append(profile.DeadlineCalibration.Cells, cell)
	pr.FirstContentDeadline = now.Add(10 * time.Second)
	// Cooled admission and the exact competing-work envelope are separate policies.
	boundedPrediction := func(e forecast.Evidence) bool {
		e.Calibration.Calibration = profile.DeadlineCalibration
		_, _, ok := performance.PredictCalibrated(e.Calibration, performance.IncomingWork{
			PromptWork: pr.PromptWork, PromptTokens: pr.PromptWork.UpperBoundTokens, RequestedMaxTokens: pr.RequestedMaxTokens,
		}, forecast.CapacityFreshness, forecast.PerformanceFreshness, forecast.DecodeAllowance)
		return ok
	}
	c, evidence := f.evaluate(pr, now).Estimate, f.evidence(pr, now)
	if c.Status != forecast.Unknown || c.PredictionSource != "" ||
		!evidence.Calibration.WorkKnown || evidence.Calibration.Work.OtherModelRequests != 1 || !boundedPrediction(evidence) {
		t.Fatalf("bounded exact competitor lost its work or bypassed cooled admission: %+v", c)
	}
	p.BackendCapacity.Slots[1].DeadlineProfile.ID = "unknown-runtime"
	c, evidence = f.evaluate(pr, now).Estimate, f.evidence(pr, now)
	if c.Status != forecast.Unknown || c.PredictionSource != "" ||
		evidence.Calibration.WorkKnown || boundedPrediction(evidence) {
		t.Fatalf("unreviewed competitor borrowed envelope: %+v", c)
	}
	p.BackendCapacity.Slots[1].DeadlineProfile.ID = other.ID
	p.BackendCapacity.Slots[1].DeadlineWork.ServiceFraction = .125
	*p.BackendCapacity.WholeMacServiceUsed = .125
	c, evidence = f.evaluate(pr, now).Estimate, f.evidence(pr, now)
	if c.Status != forecast.Unknown || c.PredictionSource != "" ||
		!evidence.Calibration.WorkKnown || boundedPrediction(evidence) {
		t.Fatalf("heavier competitor borrowed envelope: %+v", c)
	}
}

func TestCalibratedPreflightAndDispatchSharePromptEvidence(t *testing.T) {
	now := time.Now()
	r, p, _, pr := calibratedCandidateFixture(t, now)
	// An underestimated heuristic must not survive a preflight copy.
	pr.EstimatedPromptTokens, pr.FirstContentPromptTokens = 100, 100
	count, _, _, ttft, known := r.QuickFirstContentCapacityForRequest("model", pr)
	if count != 1 || !known || ttft != 3663*time.Millisecond {
		t.Fatalf("preflight count=%d known=%t TTFT=%s", count, known, ttft)
	}
	pr.RequestID = "calibrated-dispatch"
	selected, decision := r.ReserveProviderEx("model", pr)
	if selected != p || decision.FirstContent.PredictionSource != "qualified_calibration" || decision.FirstContent.ConservativeMs != 3663 {
		t.Fatalf("dispatch diverged from preflight: selected=%v decision=%+v", selected, decision)
	}
	p.RemovePending(pr.RequestID)
	// The calibrated latency path cannot reduce the original output commitment.
	p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 1000
	pr.RequestedMaxTokens = 2000
	selected, _ = r.ReserveProviderEx("model", pr)
	if selected != nil {
		t.Fatal("calibrated forecast bypassed physical token budget")
	}
}
