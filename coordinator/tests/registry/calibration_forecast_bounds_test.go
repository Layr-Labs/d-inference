package registry_test

import (
	"fmt"
	"math"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/forecast"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/performance"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry/firstcontent"
)

func TestCalibratedFirstContentUsesQualifiedBoundWithoutIncomingCompletion(t *testing.T) {
	now := time.Now()
	f := newCalibrationPolicyFixture(t, now)
	pr := f.request
	c := f.evaluate(pr, now).Estimate
	if c.Status != forecast.Feasible || c.PredictionSource != "qualified_calibration" || math.Abs(c.ConservativeMs-3663) > 1e-8 {
		t.Fatalf("qualified forecast: %+v", c)
	}
	// Incoming output reserves memory but only <=33 decode tokens belong to TTFT.
	pr.RequestedMaxTokens = 28000
	large := f.evaluate(pr, now).Estimate
	if large != c {
		t.Fatalf("incoming output changed first-content work: %+v vs %+v", large, c)
	}
	pr.FirstContentDeadline = now.Add(time.Second)
	if got := f.evaluate(pr, now).Estimate; got.Status != forecast.PredictedLate || got.BudgetMs != 1000 {
		t.Fatalf("original deadline extended: %+v", got)
	}
	assertCalibratedRootBinding(t)
}

func TestCalibratedFirstContentFallbackPreservesEvidenceRequirements(t *testing.T) {
	for _, tc := range []struct {
		name   string
		change func(*calibrationPolicyFixture)
	}{
		{"heuristic", func(f *calibrationPolicyFixture) { f.request.PromptWork.Source = protocol.PromptWorkHeuristic }},
		{"artifact", func(f *calibrationPolicyFixture) { f.request.PromptWork.ModelArtifactHash = strings.Repeat("e", 64) }},
		{"template", func(f *calibrationPolicyFixture) { f.request.PromptWork.PromptContractID = strings.Repeat("e", 64) }},
		{"work unknown", func(f *calibrationPolicyFixture) { f.provider.BackendCapacity.Slots[0].DeadlineWork.Known = false }},
		{"work epoch", func(f *calibrationPolicyFixture) { f.provider.BackendCapacity.Slots[0].DeadlineWork.Epoch = "old" }},
		{"stale performance", func(f *calibrationPolicyFixture) {
			p := f.provider
			p.BackendCapacity.Slots[0].PerformanceMeasurements.IsolatedPrefill.SampleAgeMS = (3 * time.Minute).Milliseconds()
			f.history.Reconcile(p.BackendCapacity, p.CapacityAcceptedAt, p.CapacityAcceptedAt, time.Second)
		}},
		{"stale capacity", func(f *calibrationPolicyFixture) {
			f.provider.CapacityAcceptedAt = f.provider.CapacityAcceptedAt.Add(-6 * time.Second)
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			now := time.Now()
			f := newCalibrationPolicyFixture(t, now)
			tc.change(f)
			got := f.evaluate(f.request, now).Estimate
			if got.PredictionSource != "" || got.ConservativeMs < 3330 {
				t.Fatalf("unqualified evidence bypassed observed-rate work or delivery costs: %+v", got)
			}
			f.request.RequestID = "unqualified-root-check"
			selected, decision := f.registry.ReserveProviderEx(f.request.Model, f.request)
			if selected != f.provider || decision.FirstContent.PredictionSource != "" || decision.FirstContent.ConservativeMs < 3330 {
				t.Fatalf("unqualified evidence bypassed registered root fallback: %+v", decision)
			}
			f.provider.RemovePending(f.request.RequestID)
		})
	}
}

func TestCalibratedFirstContentRequiresContextForEarlyDecode(t *testing.T) {
	for _, tc := range []struct {
		prompt, output int
		qualified      bool
	}{
		{4096, 33, false}, {4063, 33, true}, {4063, 32000, true},
		{4095, 1, true}, {4095, 2, false},
	} {
		t.Run(fmt.Sprintf("prompt%d-output%d", tc.prompt, tc.output), func(t *testing.T) {
			now := time.Now()
			f := newCalibrationPolicyFixture(t, now)
			for i := range f.profile.DeadlineCalibration.Cells {
				f.profile.DeadlineCalibration.Cells[i].PromptTokensMax = 4096
				f.profile.DeadlineCalibration.Cells[i].ContextTokensMax = 4096
			}
			pr := f.request
			pr.PromptWork.PromptTokens, pr.PromptWork.UpperBoundTokens = tc.prompt, tc.prompt
			pr.RequestedMaxTokens = tc.output
			pr.FirstContentDeadline = now.Add(10 * time.Second)
			estimate := f.evaluate(pr, now).Estimate
			if qualified := estimate.PredictionSource == "qualified_calibration"; qualified != tc.qualified {
				t.Fatalf("qualified=%v, want %v: %+v", qualified, tc.qualified, estimate)
			}
		})
	}
	assertCalibratedRootBinding(t)
}

func TestCalibratedFirstContentBoundsBusyWorkAndContext(t *testing.T) {
	now := time.Now()
	f := newCalibrationPolicyFixture(t, now)
	p, profile, pr := f.provider, f.profile, f.request
	slot := &p.BackendCapacity.Slots[0]
	slot.State, slot.NumRunning = "running", 1
	slot.DeadlineWork.PrefillTokens, slot.DeadlineWork.DecodeTokens = 15500, 500
	slot.DeadlineWork.RequestCount, slot.DeadlineWork.ContextTokensMax = 1, 16000
	slot.DeadlineWork.ServiceFraction = .0625
	*p.BackendCapacity.WholeMacServiceUsed = .0625
	*slot.Telemetry.PartialPrefillRows = 1
	pr.FirstContentDeadline = now.Add(20 * time.Second)
	got := f.evaluate(pr, now).Estimate
	if got.PredictionSource != "" || got.Status != forecast.Unknown {
		t.Fatalf("busy provider bypassed cooled applicability: %+v", got)
	}
	// Exercise bounded-work pricing independently of the idle-only promotion.
	predict := func() (firstcontent.Prediction, bool) {
		e := f.evidence(pr, now).Calibration
		e.Calibration = profile.DeadlineCalibration
		prediction, _, ok := performance.PredictCalibrated(e, performance.IncomingWork{
			PromptWork: pr.PromptWork, PromptTokens: pr.PromptWork.UpperBoundTokens, RequestedMaxTokens: pr.RequestedMaxTokens,
		}, forecast.CapacityFreshness, forecast.PerformanceFreshness, forecast.DecodeAllowance)
		return prediction, ok
	}
	if prediction, ok := predict(); !ok || math.Abs(prediction.ConservativeMS-27413) > 1e-8 {
		t.Fatalf("bounded busy work lost its priced envelope: %+v, %v", prediction, ok)
	}
	profile.DeadlineCalibration.Cells[1].PromptTokensMax = 8000
	profile.DeadlineCalibration.Cells[1].ContextTokensMax = 8000
	if prediction, ok := predict(); ok {
		t.Fatalf("long existing context borrowed short-context cell: %+v", prediction)
	}
	profile.DeadlineCalibration.Cells[1].PromptTokensMax = 32768
	profile.DeadlineCalibration.Cells[1].ContextTokensMax = 32768
	p.BackendCapacity.Slots[0].PerformanceMeasurements.ContendedPrefill.SampleAgeMS = (3*time.Minute - time.Second).Milliseconds()
	f.history.Reconcile(p.BackendCapacity, p.CapacityAcceptedAt, now, time.Second)
	if prediction, ok := predict(); ok {
		t.Fatalf("busy work used stale contended rate: %+v", prediction)
	}
	pr.RequestID = "busy-root-check"
	selected, decision := f.registry.ReserveProviderEx(pr.Model, pr)
	if selected != p || decision.FirstContent.PredictionSource != "" || decision.FirstContent.Status != forecast.Unknown {
		t.Fatalf("busy provider bypassed registered root posture: %+v", decision)
	}
	p.RemovePending(pr.RequestID)
}
