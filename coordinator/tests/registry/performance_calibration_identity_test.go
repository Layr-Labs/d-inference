package registry_test

import (
	"testing"
	"testing/synctest"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/capacityvalue"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/measurements"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestCalibratedSnapshotOwnsWireFields(t *testing.T) {
	identity, profile, _ := reviewedProfileEvidence(t)
	source := &identity.Capacity.Slots[0]
	quiescence, stability := 20000, 5000
	source.DeadlineProfile = &protocol.DeadlinePerformanceProfileReference{
		MinimumWholeMacQuiescenceMS: &quiescence, MinimumNominalStabilityMS: &stability, PowerMode: "automatic",
		ID: "test-only-deadline", RuntimeRevision: profile.RuntimeRevision, ConfiguredContextTokens: profile.ContextTokensMax,
		EffectiveMaxConcurrency: profile.MaxConcurrency, PrefillChunkSize: 512, MaxConcurrentPartialPrefills: 1,
	}
	source.DeadlineWork = &protocol.DeadlineWork{Version: 1, Epoch: "epoch", Known: true}
	fixed := 0
	source.PerformanceProfile.MTP = &protocol.ServingMTPIdentity{FixedDraftTokens: &fixed}
	source.DeadlineProfile.MTP = &protocol.ServingMTPIdentity{FixedDraftTokens: &fixed}
	stripe, mixed := 4096, 256
	source.DeadlineProfile.SoloPrefillStripeTokens = &stripe
	source.DeadlineProfile.MixedPrefillTokenCap = &mixed
	var cloned protocol.BackendSlotCapacity
	capacityvalue.CloneBackendSlot(&cloned, source)
	cloned.DeadlineWork.Known = false
	*cloned.PerformanceProfile.MTP.FixedDraftTokens = 1
	*cloned.DeadlineProfile.MTP.FixedDraftTokens = 2
	*cloned.DeadlineProfile.SoloPrefillStripeTokens = 1
	*cloned.DeadlineProfile.MixedPrefillTokenCap = 1
	if !source.DeadlineWork.Known || fixed != 0 || stripe != 4096 || mixed != 256 {
		t.Fatal("accepted capacity aliases mutable caller evidence")
	}
}

func TestContendedMeasurementFreshnessUsesSampleIdentity(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		now := time.Now()
		history := new(measurements.History)
		reg, p, _ := reviewedServingProvider(t, func(deps *production.Dependencies) {
			deps.Measurements = func(string) *measurements.History { return history }
		})
		p.Mu().Lock()
		slot := &p.BackendCapacity.Slots[0]
		slot.Telemetry = &protocol.SlotTelemetry{QueuedPrefillTokens: new(int64), PartialPrefillRows: new(int64)}
		rate := func(tps float64) *protocol.PerformanceRateObservation {
			return &protocol.PerformanceRateObservation{TokensPerSecond: tps, SampleCount: 1}
		}
		slot.PerformanceMeasurements = &protocol.PerformanceMeasurements{Epoch: "epoch", IsolatedPrefill: rate(2000), ContendedPrefill: rate(1000), Decode: rate(100)}
		capacity := p.BackendCapacity
		p.Mu().Unlock()
		reg.Heartbeat(p.ID, soloHeartbeat(capacity.Slots))
		original, _ := history.Lookup("model")
		time.Sleep(3 * time.Minute)
		later := now.Add(3 * time.Minute)
		reg.Heartbeat(p.ID, soloHeartbeat(capacity.Slots))
		unchanged, _ := history.Lookup("model")
		if !unchanged.ContendedObservedAfter.Equal(original.ContendedObservedAfter) {
			t.Fatal("heartbeat rejuvenated unchanged contended observation")
		}
		sample := capacity.Slots[0].PerformanceMeasurements.ContendedPrefill
		sample.SampleCount++
		reg.Heartbeat(p.ID, soloHeartbeat(capacity.Slots))
		changed, _ := history.Lookup("model")
		if !changed.ContendedObservedAfter.Equal(later.Add(-time.Second)) {
			t.Fatal("new contended observation failed to refresh")
		}
	})
}
