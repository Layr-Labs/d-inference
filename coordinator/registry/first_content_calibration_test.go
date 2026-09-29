package registry

import (
	"fmt"
	"math"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry/firstcontent"
)

// This is a synthetic arithmetic fixture, never a catalog promotion or measured
// claim about the test fixture's hardware name.
func calibratedCandidateFixture(t *testing.T, now time.Time) (*Registry, *Provider, *deadlinePerformanceProfile, *PendingRequest) {
	t.Helper()
	p, serving := reviewedProfileFixture(t)
	quiescence, stability := 0, 5000
	profile := &deadlinePerformanceProfile{
		MinimumWholeMacQuiescenceMS: &quiescence, MinimumNominalStabilityMS: &stability, PowerMode: "automatic",
		ID: "test-only-deadline", ModelID: serving.ModelID, ArtifactSHA256: serving.ArtifactSHA256,
		ProviderVersion: serving.ProviderVersion, RuntimeRevision: serving.RuntimeRevision,
		KVBackend: serving.KVBackend, ChipName: serving.ChipName, GPUCores: serving.GPUCores, MemoryGB: serving.MemoryGB,
		ConfiguredContextTokens: serving.ContextTokensMax, EffectiveMaxConcurrency: serving.MaxConcurrency,
		PrefillChunkSize: 512, MaxConcurrentPartialPrefills: 1, QualificationReportSHA256: serving.QualificationReportSHA256,
	}
	previous := reviewedDeadlinePerformanceProfiles
	reviewedDeadlinePerformanceProfiles = map[string]*deadlinePerformanceProfile{profile.ID: profile}
	t.Cleanup(func() { reviewedDeadlinePerformanceProfiles = previous })
	profile.DeadlineCalibration = &firstcontent.Calibration{Version: 1, PromptContractID: strings.Repeat("c", 64), Cells: []firstcontent.Cell{{
		PromptTokensMin: 1, PromptTokensMax: 32768, ContextTokensMin: 1, ContextTokensMax: 32768,
		CacheState: "cold", Contention: "isolated", PrefillTPS: 2000, DecodeTPS: 100,
		MaxPrefillWorkTokens: 65536, MaxDecodeWorkTokens: 4096, MaxActiveRequests: 1,
		ErrorRatio: 1.1, ErrorAdditiveMS: 100, CalibrationSampleCount: 20,
		ValidationSampleCount: 100, ValidationCoveredCount: 100, TailCoverage: .95, ReportSHA256: strings.Repeat("d", 64),
	}}}
	cell := profile.DeadlineCalibration.Cells[0]
	cell.Contention, cell.MaxActiveRequests = "same_model", 16
	profile.DeadlineCalibration.Cells = append(profile.DeadlineCalibration.Cells, cell)
	p.pendingReqs = make(map[string]*PendingRequest)
	p.CapacityAcceptedAt = now
	p.SystemMetrics.ThermalState = "nominal"
	p.BackendCapacity.Telemetry = &protocol.CapacityTelemetry{LowPowerMode: new(bool)}
	p.BackendCapacity.WholeMacServiceUsed = new(float64)
	slot := &p.BackendCapacity.Slots[0]
	slot.PromptWorkIdentity = &protocol.PromptWorkIdentity{ModelArtifactHash: profile.ArtifactSHA256, PromptContractID: profile.DeadlineCalibration.PromptContractID}
	slot.DeadlineProfile = &protocol.DeadlinePerformanceProfileReference{
		MinimumWholeMacQuiescenceMS: &quiescence, MinimumNominalStabilityMS: &stability, PowerMode: "automatic",
		ID: profile.ID, RuntimeRevision: profile.RuntimeRevision, ConfiguredContextTokens: profile.ConfiguredContextTokens,
		EffectiveMaxConcurrency: profile.EffectiveMaxConcurrency, PrefillChunkSize: profile.PrefillChunkSize,
		MaxConcurrentPartialPrefills: profile.MaxConcurrentPartialPrefills,
	}
	slot.State, slot.ObservedPrefillTPS, slot.ObservedDecodeTPS = "idle", 2000, 100
	slot.Telemetry = &protocol.SlotTelemetry{QueuedPrefillTokens: new(int64), PartialPrefillRows: new(int64)}
	rate := func(tps float64) *protocol.PerformanceRateObservation {
		return &protocol.PerformanceRateObservation{TokensPerSecond: tps, SampleCount: 1}
	}
	slot.PerformanceMeasurements = &protocol.PerformanceMeasurements{Epoch: "epoch", IsolatedPrefill: rate(2000), ContendedPrefill: rate(1000), Decode: rate(100)}
	slot.DeadlineWork = &protocol.DeadlineWork{Version: 1, Epoch: "epoch", Known: true}
	p.reconcileFirstContentMeasurementsLocked(p.BackendCapacity, now)
	pr := &PendingRequest{Model: "model", EstimatedPromptTokens: 4000, FirstContentPromptTokens: 4000, RequestedMaxTokens: 128, FirstContentDeadline: now.Add(4 * time.Second),
		PromptWork: &protocol.PromptWork{Version: 1, Source: protocol.PromptWorkExact, PromptTokens: 4000, UpperBoundTokens: 4000, PromptContractID: profile.DeadlineCalibration.PromptContractID, ModelArtifactHash: profile.ArtifactSHA256}}
	return New(testLogger()), p, profile, pr
}

func calibratedForecast(r *Registry, p *Provider, pr *PendingRequest, now time.Time) *routingCandidate {
	c := &routingCandidate{}
	r.fillRoutingSnapshotPLocked(&c.snapshot, p, pr.Model, now)
	r.estimateFirstContent(c, pr, now)
	return c
}

func TestCalibratedFirstContentUsesQualifiedBoundWithoutIncomingCompletion(t *testing.T) {
	now := time.Now()
	r, p, _, pr := calibratedCandidateFixture(t, now)
	c := calibratedForecast(r, p, pr, now)
	if c.firstContent.Status != FirstContentFeasible || c.firstContent.PredictionSource != "qualified_calibration" || math.Abs(c.firstContent.ConservativeMs-3663) > 1e-8 {
		t.Fatalf("qualified forecast: %+v", c.firstContent)
	}
	// Incoming output reserves memory but only <=33 decode tokens belong to TTFT.
	pr.RequestedMaxTokens = 28000
	large := calibratedForecast(r, p, pr, now)
	if large.firstContent != c.firstContent {
		t.Fatalf("incoming output changed first-content work: %+v vs %+v", large.firstContent, c.firstContent)
	}
	pr.FirstContentDeadline = now.Add(time.Second)
	if got := calibratedForecast(r, p, pr, now).firstContent; got.Status != FirstContentPredictedLate || got.BudgetMs != 1000 {
		t.Fatalf("original deadline extended: %+v", got)
	}
}

func TestCalibratedFirstContentFallbackPreservesEvidenceRequirements(t *testing.T) {
	for _, tc := range []struct {
		name   string
		change func(*Provider, *PendingRequest)
	}{
		{"heuristic", func(p *Provider, pr *PendingRequest) { pr.PromptWork.Source = protocol.PromptWorkHeuristic }},
		{"artifact", func(p *Provider, pr *PendingRequest) { pr.PromptWork.ModelArtifactHash = strings.Repeat("e", 64) }},
		{"template", func(p *Provider, pr *PendingRequest) { pr.PromptWork.PromptContractID = strings.Repeat("e", 64) }},
		{"work unknown", func(p *Provider, pr *PendingRequest) { p.BackendCapacity.Slots[0].DeadlineWork.Known = false }},
		{"work epoch", func(p *Provider, pr *PendingRequest) { p.BackendCapacity.Slots[0].DeadlineWork.Epoch = "old" }},
		{"stale performance", func(p *Provider, pr *PendingRequest) {
			m := p.firstContentMeasurements["model"]
			m.observedAfter = m.observedAfter.Add(-3 * time.Minute)
			p.firstContentMeasurements["model"] = m
		}},
		{"stale capacity", func(p *Provider, pr *PendingRequest) {
			p.CapacityAcceptedAt = p.CapacityAcceptedAt.Add(-6 * time.Second)
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			now := time.Now()
			r, p, _, pr := calibratedCandidateFixture(t, now)
			tc.change(p, pr)
			got := calibratedForecast(r, p, pr, now).firstContent
			if got.PredictionSource != "" || got.ConservativeMs < 3330 {
				t.Fatalf("unqualified evidence bypassed observed-rate work or delivery costs: %+v", got)
			}
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
			r, p, profile, pr := calibratedCandidateFixture(t, now)
			for i := range profile.DeadlineCalibration.Cells {
				profile.DeadlineCalibration.Cells[i].PromptTokensMax = 4096
				profile.DeadlineCalibration.Cells[i].ContextTokensMax = 4096
			}
			pr.PromptWork.PromptTokens, pr.PromptWork.UpperBoundTokens = tc.prompt, tc.prompt
			pr.RequestedMaxTokens = tc.output
			pr.FirstContentDeadline = now.Add(10 * time.Second)
			forecast := calibratedForecast(r, p, pr, now).firstContent
			if qualified := forecast.PredictionSource == "qualified_calibration"; qualified != tc.qualified {
				t.Fatalf("qualified=%v, want %v: %+v", qualified, tc.qualified, forecast)
			}
		})
	}
}

func TestCalibratedFirstContentBoundsBusyWorkAndContext(t *testing.T) {
	now := time.Now()
	r, p, profile, pr := calibratedCandidateFixture(t, now)
	slot := &p.BackendCapacity.Slots[0]
	slot.State, slot.NumRunning = "running", 1
	slot.DeadlineWork.PrefillTokens, slot.DeadlineWork.DecodeTokens = 2000, 500
	slot.DeadlineWork.RequestCount, slot.DeadlineWork.ContextTokensMax = 1, 16000
	slot.DeadlineWork.ServiceFraction = .0625
	*p.BackendCapacity.WholeMacServiceUsed = .0625
	*slot.Telemetry.PartialPrefillRows = 1
	pr.FirstContentDeadline = now.Add(20 * time.Second)
	got := calibratedForecast(r, p, pr, now).firstContent
	if got.Status != FirstContentFeasible || got.PredictionSource != "qualified_calibration" || math.Abs(got.ConservativeMs-13563) > 1e-8 {
		t.Fatalf("bounded busy work did not qualify: %+v", got)
	}
	profile.DeadlineCalibration.Cells[1].ContextTokensMax = 8000
	got = calibratedForecast(r, p, pr, now).firstContent
	if got.Status != FirstContentUnknown || got.Reason != "competing_work_unknown" || got.PredictionSource != "" {
		t.Fatalf("long existing context borrowed short-context cell: %+v", got)
	}
	profile.DeadlineCalibration.Cells[1].ContextTokensMax = 32768
	m := p.firstContentMeasurements["model"]
	m.contendedObservedAfter = now.Add(-3 * time.Minute)
	p.firstContentMeasurements["model"] = m
	if got = calibratedForecast(r, p, pr, now).firstContent; got.PredictionSource != "" || got.Status != FirstContentUnknown {
		t.Fatalf("busy work used stale contended rate: %+v", got)
	}
}

func TestCalibratedFirstContentFallsBackUntilModelLoadTransitionEnds(t *testing.T) {
	now := time.Now()
	r, p, _, pr := calibratedCandidateFixture(t, now)
	before := calibratedForecast(r, p, pr, now)
	if before.firstContent.Status != FirstContentFeasible || before.firstContent.PredictionSource != "qualified_calibration" {
		t.Fatalf("idle model did not qualify before load: %+v", before.firstContent)
	}
	// Another model may be evaluating its weight shards before it appears in
	// Slots. The target's fresh, idle workload snapshot cannot bound that work.
	loading := true
	p.BackendCapacity.LoadTransitionActive = &loading
	during := calibratedForecast(r, p, pr, now)
	if during.snapshot.calibratedWorkKnown || during.firstContent.PredictionSource != "" ||
		!during.snapshot.wholeMacBusy || during.firstContent.Status != FirstContentUnknown ||
		during.firstContent.Reason != "competing_work_unknown" || during.firstContent.ConservativeMs < 3330 ||
		during.firstContent.BudgetMs != before.firstContent.BudgetMs {
		t.Fatalf("load transition borrowed idle calibration or changed deadline: %+v", during.firstContent)
	}
	loading = false
	after := calibratedForecast(r, p, pr, now)
	if !after.snapshot.calibratedWorkKnown || after.firstContent != before.firstContent {
		t.Fatalf("completed transition did not restore qualified evidence: %+v vs %+v", after.firstContent, before.firstContent)
	}
}

func TestCalibratedWorkCorrelatesPendingAndRetiringOwners(t *testing.T) {
	now := time.Now()
	r, p, _, pr := calibratedCandidateFixture(t, now)
	pending := &PendingRequest{RequestID: "existing", Model: "model", RequestedMaxTokens: 1000, PromptWork: pr.PromptWork}
	p.AddPending(pending)
	c := calibratedForecast(r, p, pr, now)
	if !c.snapshot.calibratedWorkKnown || c.snapshot.calibratedWork.PrefillTokens != 4000 || c.snapshot.calibratedWork.DecodeTokens != 1000 || c.snapshot.calibratedWork.ContextTokens != 5000 {
		t.Fatalf("unreported pending work missing: %+v", c.snapshot.calibratedWork)
	}
	slot := &p.BackendCapacity.Slots[0]
	slot.NumRunning = 1
	slot.DeadlineWork = &protocol.DeadlineWork{Version: 1, Epoch: "epoch", Known: true, PrefillTokens: 4000, DecodeTokens: 1000, RequestCount: 1, ContextTokensMax: 5000, ServiceFraction: .0625}
	*p.BackendCapacity.WholeMacServiceUsed = .0625
	p.BackendCapacity.WholeMacServiceReservations = []protocol.WholeMacServiceReservation{{ID: pending.ServiceReservationID(), UsedFraction: .0625}}
	c = calibratedForecast(r, p, pr, now)
	if !c.snapshot.calibratedWorkKnown || c.snapshot.calibratedWork.ActiveRequests != 1 || c.snapshot.calibratedWork.PrefillTokens != 4000 {
		t.Fatalf("correlated owner double charged: %+v", c.snapshot.calibratedWork)
	}
	id := pending.ServiceReservationID()
	p.pendingReqs = nil
	p.serviceRetirementShadows = map[string]float64{id: .0625}
	if c = calibratedForecast(r, p, pr, now); !c.snapshot.calibratedWorkKnown {
		t.Fatal("reported retiring work lost its bound")
	}
	p.BackendCapacity.WholeMacServiceReservations = nil
	if c = calibratedForecast(r, p, pr, now); c.snapshot.calibratedWorkKnown {
		t.Fatal("unseen retirement inferred finished from receipt time")
	}
}

func TestCalibratedWorkRejectsMissingLocalAndMaintenanceOwners(t *testing.T) {
	for _, tc := range []struct {
		name   string
		change func(*Provider)
	}{
		{"unrepresented local service", func(p *Provider) { *p.BackendCapacity.WholeMacServiceUsed = .1 }},
		{"unrepresented execution", func(p *Provider) { p.BackendCapacity.Slots[0].NumRunning = 1 }},
		{"unrepresented queued prompt", func(p *Provider) { *p.BackendCapacity.Slots[0].Telemetry.QueuedPrefillTokens = 1 }},
		{"unrepresented eval", func(p *Provider) { p.BackendCapacity.Slots[0].EvalInFlightMs = 1 }},
		{"cache maintenance", func(p *Provider) { p.BackendCapacity.Slots[0].IdleClearInFlightMs = 1 }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			now := time.Now()
			r, p, _, pr := calibratedCandidateFixture(t, now)
			tc.change(p)
			if calibratedForecast(r, p, pr, now).snapshot.calibratedWorkKnown {
				t.Fatal("unbounded work qualified")
			}
		})
	}
}
