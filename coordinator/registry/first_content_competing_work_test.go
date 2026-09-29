package registry

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"strings"
	"testing"
	"time"
)

func TestCalibratedFirstContentRequiresExactCompetingProfile(t *testing.T) {
	now := time.Now()
	r, p, profile, pr := calibratedCandidateFixture(t, now)
	other := *profile
	other.ID, other.ModelID, other.ArtifactSHA256 = "test-only-other", "other", strings.Repeat("f", 64)
	reviewedDeadlinePerformanceProfiles[other.ID] = &other
	p.Models = append(p.Models, protocol.ModelInfo{ID: other.ModelID, WeightHash: other.ArtifactSHA256})
	var slot protocol.BackendSlotCapacity
	cloneBackendSlot(&slot, &p.BackendCapacity.Slots[0])
	slot.Model, slot.State, slot.NumRunning = other.ModelID, "running", 1
	slot.DeadlineProfile.ID = other.ID
	slot.DeadlineWork = &protocol.DeadlineWork{Version: 1, Epoch: "epoch", Known: true, PrefillTokens: 1000, DecodeTokens: 100, RequestCount: 1, ContextTokensMax: 8192, ServiceFraction: .0625}
	p.BackendCapacity.Slots = append(p.BackendCapacity.Slots, slot)
	*p.BackendCapacity.WholeMacServiceUsed = .0625
	cell := profile.DeadlineCalibration.Cells[0]
	cell.Contention, cell.CompetitorProfileIDs = "other_model", []string{other.ID}
	cell.MaxActiveRequests, cell.MaxOtherModelRequests, cell.MaxOtherModelServiceFraction = 2, 1, .0625
	profile.DeadlineCalibration.Cells = append(profile.DeadlineCalibration.Cells, cell)
	pr.FirstContentDeadline = now.Add(10 * time.Second)
	c := calibratedForecast(r, p, pr, now)
	if c.firstContent.Status != FirstContentFeasible || c.firstContent.PredictionSource != "qualified_calibration" || c.snapshot.calibratedWork.OtherModelRequests != 1 {
		t.Fatalf("bounded exact competitor rejected: %+v", c.firstContent)
	}
	p.BackendCapacity.Slots[1].DeadlineProfile.ID = "unknown-runtime"
	if c = calibratedForecast(r, p, pr, now); c.firstContent.Status != FirstContentUnknown || c.firstContent.PredictionSource != "" {
		t.Fatalf("unreviewed competitor borrowed envelope: %+v", c.firstContent)
	}
	p.BackendCapacity.Slots[1].DeadlineProfile.ID = other.ID
	p.BackendCapacity.Slots[1].DeadlineWork.ServiceFraction = .125
	*p.BackendCapacity.WholeMacServiceUsed = .125
	if c = calibratedForecast(r, p, pr, now); c.firstContent.Status != FirstContentUnknown || c.firstContent.PredictionSource != "" {
		t.Fatalf("heavier competitor borrowed envelope: %+v", c.firstContent)
	}
}

func TestCalibratedPreflightAndDispatchSharePromptEvidence(t *testing.T) {
	now := time.Now()
	r, fixture, _, pr := calibratedCandidateFixture(t, now)
	p := makeSchedulerProvider(t, r, "calibrated-provider", "model", 100)
	p.Version, p.Hardware, p.Models = fixture.Version, fixture.Hardware, fixture.Models
	p.BackendCapacity, p.CapacityAcceptedAt, p.firstContentMeasurements = fixture.BackendCapacity, fixture.CapacityAcceptedAt, fixture.firstContentMeasurements
	// An underestimated heuristic must not survive a preflight copy; the exact
	// input is shared with dispatch even though no cache routing is configured.
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
