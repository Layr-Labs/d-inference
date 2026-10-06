package registry_test

import (
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/deadline"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/measurements"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/performance"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry/firstcontent"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// This is a synthetic arithmetic fixture, never a catalog promotion or measured
// claim about the test fixture's hardware name.
func calibratedCandidateFixture(t *testing.T, now time.Time, configure ...func(*deadline.Profile) []*deadline.Profile) (*production.Registry, *production.Provider, *deadline.Profile, *production.PendingRequest) {
	return calibratedCandidateFixtureWithDependencies(t, now, nil, configure...)
}

func calibratedCandidateFixtureWithDependencies(t *testing.T, now time.Time, configureDeps func(*production.Dependencies), configure ...func(*deadline.Profile) []*deadline.Profile) (*production.Registry, *production.Provider, *deadline.Profile, *production.PendingRequest) {
	t.Helper()
	serving := syntheticServingProfile()
	backend := "paged"
	capacity := &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{{
		Model: serving.ModelID, MaxConcurrency: 16, ActiveTokenBudgetMax: 100000,
		KVBackend: &backend, PerformanceProfile: &protocol.ServingPerformanceProfileReference{
			ID: serving.ID, RuntimeRevision: serving.RuntimeRevision, ContextTokens: 32768},
	}}}
	quiescence, stability := 20000, 5000
	profile := &deadline.Profile{
		MinimumWholeMacQuiescenceMS: &quiescence, MinimumNominalStabilityMS: &stability, PowerMode: "automatic",
		ID: "test-only-deadline", ModelID: serving.ModelID, ArtifactSHA256: serving.ArtifactSHA256,
		ProviderVersion: serving.ProviderVersion, RuntimeRevision: serving.RuntimeRevision,
		KVBackend: serving.KVBackend, ChipName: serving.ChipName, GPUCores: serving.GPUCores, MemoryGB: serving.MemoryGB,
		ConfiguredContextTokens: serving.ContextTokensMax, EffectiveMaxConcurrency: serving.MaxConcurrency,
		PrefillChunkSize: 512, MaxConcurrentPartialPrefills: 1, QualificationReportSHA256: serving.QualificationReportSHA256,
	}
	profile.DeadlineCalibration = &firstcontent.Calibration{Version: 1, PromptContractID: strings.Repeat("c", 64), Cells: []firstcontent.Cell{{
		PromptTokensMin: 1, PromptTokensMax: 32768, ContextTokensMin: 1, ContextTokensMax: 32768,
		CacheState: "cold", Contention: "isolated", PrefillTPS: 2000, DecodeTPS: 100,
		MaxPrefillWorkTokens: 65536, MaxDecodeWorkTokens: 4096, MaxActiveRequests: 1,
		ErrorRatio: 1.1, ErrorAdditiveMS: 100, CalibrationSampleCount: 20,
		ValidationSampleCount: 100, ValidationCoveredCount: 100, TailCoverage: .95, ReportSHA256: profile.QualificationReportSHA256,
	}}}
	cell := profile.DeadlineCalibration.Cells[0]
	cell.Contention, cell.MaxActiveRequests = "same_model", 16
	profile.DeadlineCalibration.Cells = append(profile.DeadlineCalibration.Cells, cell)
	// Integrated fixtures use the supported release identity, while their pure
	// profile inputs retain the synthetic arithmetic evidence.
	profile.ProviderVersion, serving.ProviderVersion = "1.0.0", "1.0.0"
	profiles := []*deadline.Profile{(*deadline.Profile)(profile)}
	for _, configure := range configure {
		for _, additional := range configure(profile) {
			profiles = append(profiles, (*deadline.Profile)(additional))
		}
	}
	deps := production.Dependencies{
		DeadlineProfiles:    deadline.NewCatalog(profiles...),
		PerformanceProfiles: performance.NewCatalog(serving),
		Measurements:        func(string) *measurements.History { return &measurements.History{} },
	}
	if configureDeps != nil {
		configureDeps(&deps)
	}
	newHistory := deps.Measurements
	var history *measurements.History
	deps.Measurements = func(id string) *measurements.History { history = newHistory(id); return history }
	r := production.NewWithDependencies(testLogger(), deps)
	msg := testRegisterMessage()
	msg.Hardware = protocol.Hardware{ChipName: serving.ChipName, GPUCores: 80, MemoryGB: 192}
	msg.Models, msg.Version = []protocol.ModelInfo{{ID: serving.ModelID, WeightHash: serving.ArtifactSHA256}}, profile.ProviderVersion
	p := r.Register("calibrated-provider", nil, msg)
	p.SetVersion(msg.Version)
	testMakeTextRoutable(p)
	p.BackendCapacity = capacity
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
	history.Reconcile(p.BackendCapacity, p.CapacityAcceptedAt, now, time.Second)
	pr := &production.PendingRequest{Model: "model", EstimatedPromptTokens: 4000, FirstContentPromptTokens: 4000, RequestedMaxTokens: 128, FirstContentDeadline: now.Add(4 * time.Second),
		PromptWork: &protocol.PromptWork{Version: 1, Source: protocol.PromptWorkExact, PromptTokens: 4000, UpperBoundTokens: 4000, PromptContractID: profile.DeadlineCalibration.PromptContractID, ModelArtifactHash: profile.ArtifactSHA256}}
	return r, p, profile, pr
}
