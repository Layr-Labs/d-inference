package registry_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheplan"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/deadline"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/forecast"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/measurements"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/performance"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/promptidentity"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/selection"
)

type calibrationPolicyFixture struct {
	registry   *production.Registry
	provider   *production.Provider
	profile    *deadline.Profile
	request    *production.PendingRequest
	catalog    *deadline.Catalog
	serving    *performance.Catalog
	history    *measurements.History
	posture    deadline.PosturePolicy
	planner    *production.ReservationPlanner
	generation *cacheplan.Generation
}

func newCalibrationPolicyFixture(t *testing.T, now time.Time, configure ...func(*deadline.Profile) []*deadline.Profile) *calibrationPolicyFixture {
	return newCalibrationPolicyFixtureWithDependencies(t, now, nil, configure...)
}

func newCalibrationPolicyFixtureWithDependencies(t *testing.T, now time.Time, configureDeps func(*production.Dependencies), configure ...func(*deadline.Profile) []*deadline.Profile) *calibrationPolicyFixture {
	t.Helper()
	f := &calibrationPolicyFixture{}
	f.registry, f.provider, f.profile, f.request = calibratedCandidateFixtureWithDependencies(t, now, func(deps *production.Dependencies) {
		if configureDeps != nil {
			configureDeps(deps)
		}
		f.catalog, f.serving = deps.DeadlineProfiles, deps.PerformanceProfiles
		newHistory := deps.Measurements
		deps.Measurements = func(id string) *measurements.History { f.history = newHistory(id); return f.history }
		newPosture := deps.DeadlinePosture
		deps.DeadlinePosture = func(id string, posture *deadline.Posture) deadline.PosturePolicy {
			f.posture = posture
			if newPosture != nil {
				f.posture = newPosture(id, posture)
			}
			return f.posture
		}
		newPlanner := deps.Reservations
		deps.Reservations = func(planner *production.ReservationPlanner) production.ReservationPreparation {
			f.planner = planner
			if newPlanner != nil {
				return newPlanner(planner)
			}
			return planner
		}
		newGeneration := deps.Cache.Generations
		deps.Cache.Generations = func() *cacheplan.Generation {
			f.generation = &cacheplan.Generation{}
			if newGeneration != nil {
				f.generation = newGeneration()
			}
			return f.generation
		}
	}, configure...)
	return f
}

func (f *calibrationPolicyFixture) promptIdentity(model string) (string, string) {
	p := f.provider
	var disk, memory *protocol.PrefixCacheV2Capability
	if capability, ok := p.PrefixCacheV2Models[model]; ok {
		disk = &capability
	}
	if capability, ok := p.PrefixCacheMemoryModels[model]; ok {
		memory = &capability
	}
	return promptidentity.Resolve(model, p.Models, p.BackendCapacity, disk, memory)
}

func (f *calibrationPolicyFixture) identity() deadline.Identity {
	p := f.provider
	return deadline.Identity{Version: p.Version, Hardware: p.Hardware, Models: p.Models, Capacity: p.BackendCapacity, Metrics: p.SystemMetrics}
}

func (f *calibrationPolicyFixture) deadlineApplicable(profile *deadline.Profile, now time.Time) bool {
	eligibility := f.planner.PrepareEligibility()
	defer eligibility.Close()
	return eligibility.DeadlineApplicable(f.provider.ID, profile, now)
}

// These fixtures have one slot and no transport/cache benefit. Compose only
// those evidence inputs, using the actual qualification, work and history owners.
func (f *calibrationPolicyFixture) evidence(pr *production.PendingRequest, now time.Time) forecast.Evidence {
	p := f.provider
	slot := p.BackendCapacity.Slots[0]
	identity := f.identity()
	work, known := deadline.BoundSlots(f.catalog, identity, pr.Model)
	sample, _ := f.history.Lookup(pr.Model)
	artifact, contract := f.promptIdentity(pr.Model)
	age := func(at time.Time) int32 {
		if at.IsZero() {
			return -1
		}
		return selection.HeartbeatAgeMs(now, at)
	}
	calibration := performance.CalibrationEvidence{
		WorkKnown: known, HasCapacity: true, CapacityAgeMS: age(p.CapacityAcceptedAt), ModelLoaded: true,
		PromptWorkArtifactHash: artifact, PromptWorkContractID: contract,
		PerformanceAgeMS:   max(age(sample.ObservedAfter), age(sample.DecodeObservedAfter)),
		IsolatedPrefillTPS: sample.Rate, IsolatedInitialized: !sample.ObservedAfter.IsZero(),
		ContendedPerformanceAgeMS: max(age(sample.ContendedObservedAfter), age(sample.DecodeObservedAfter)),
		ContendedPrefillTPS:       sample.ContendedRate, DecodeTPS: sample.DecodeRate,
	}
	if known {
		calibration.Work = work.Finish()
	}
	if profile := f.catalog.Qualified(identity, pr.Model); profile != nil {
		calibration.ArtifactSHA256, calibration.ConfiguredContextTokens = profile.ArtifactSHA256, profile.ConfiguredContextTokens
		if f.deadlineApplicable(profile, now) {
			calibration.Calibration = profile.DeadlineCalibration
		}
	}
	profile := f.serving.Qualified(performance.Identity{Version: p.Version, Hardware: p.Hardware, Models: p.Models,
		Capacity: p.BackendCapacity, ThermalState: p.SystemMetrics.ThermalState}, pr.Model)
	rates := performance.Rates{Profile: profile, StaticPrefill: p.PrefillTPS, ObservedPrefill: slot.ObservedPrefillTPS,
		StaticDecode: p.DecodeTPS, ObservedDecode: slot.ObservedDecodeTPS, ObservedBatch: slot.NumRunning, Occupancy: slot.NumRunning}
	return forecast.Evidence{Calibration: calibration, CapacityAcceptedAt: p.CapacityAcceptedAt,
		ObservedDecodeTPS: slot.ObservedDecodeTPS, PrefillTPS: rates.Prefill(), DecodeTPS: rates.ProjectedDecode(slot.NumRunning, 0, false), LoadFactor: warmplan.DecodeLoadFactor,
		Workload:  forecast.Workload{WholeMacKnown: true, WholeMacBusy: !deadline.ReportedQuiescent(p.BackendCapacity), PartialPrefillRows: int(*slot.Telemetry.PartialPrefillRows)},
		Transport: forecast.Transport{AgeMS: -1}}
}

func (f *calibrationPolicyFixture) evaluate(pr *production.PendingRequest, now time.Time, benefits ...forecast.CacheBenefit) forecast.Result {
	e := f.evidence(pr, now)
	matched := e.Calibration.PromptWorkContractID != "" && pr.CachePlan.PromptContractID == e.Calibration.PromptWorkContractID && pr.CachePlan.ModelAggregateHash == e.Calibration.PromptWorkArtifactHash
	prompt, upper := forecast.PromptCounts(pr.EstimatedPromptTokens, pr.FirstContentPromptTokens, pr.PromptWork,
		e.Calibration.PromptWorkArtifactHash, e.Calibration.PromptWorkContractID, pr.CachePlan.PromptTokenCount,
		matched && pr.CachePlan.Authenticates(f.generation) && f.generation.Active() && pr.CachePlan.Present())
	request := forecast.Request{PromptTokens: prompt, UpperBoundTokens: upper, Deadline: pr.FirstContentDeadline,
		FreshAfter: pr.RequireFreshFeasibleAfter, MaxTTFTMS: pr.MaxTTFTMs, Hedge: pr.Hedge, RequireFreshFeasible: pr.RequireFreshFeasible, PlanningHorizon: pr.FirstContentPlanningHorizon,
		Incoming: performance.IncomingWork{RequiresVision: pr.RequiresVision, PromptWork: pr.PromptWork, RequestedMaxTokens: pr.RequestedMaxTokens}}
	if !pr.CachePlan.Present() || matched {
		for _, benefit := range benefits {
			benefit.Apply(&request, now)
		}
	}
	return forecast.Evaluate(e, request, now)
}

func assertCalibratedRootBinding(t *testing.T) {
	t.Helper()
	f := newCalibrationPolicyFixture(t, time.Now())
	f.request.RequestID = "calibration-root-binding"
	selected, decision := f.registry.ReserveProviderEx(f.request.Model, f.request)
	if selected != f.provider || decision.FirstContent.PredictionSource != "qualified_calibration" || decision.FirstContent.ConservativeMs != 3663 {
		t.Fatalf("retained calibration did not reach registered root routing: %+v", decision)
	}
	f.provider.RemovePending(f.request.RequestID)
}
