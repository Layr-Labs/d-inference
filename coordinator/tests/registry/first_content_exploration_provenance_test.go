package registry_test

import (
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/identitygate"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/measurements"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func explicitDecodeObservation(model string, rate float64, count int64, at time.Time) measurements.DecodeObservation {
	return measurements.DecodeObservation{Model: model, Rate: rate, Epoch: "epoch", SampleCount: count, ObservedAfter: at}
}

func TestExplorationMigrationPreservesHealthyClearChronology(t *testing.T) {
	for _, priorSourceRates := range []bool{false, true} {
		for _, newerClear := range []bool{false, true} {
			t.Run(fmt.Sprintf("prior_rates_%v/newer_clear_%v", priorSourceRates, newerClear), func(t *testing.T) {
				gates, clock := newExplorationMemoryDirectory()
				source, destination := gates.Attach("source"), gates.Attach("destination")
				gates.Bind(source, "sekey:explore", "v1")
				gates.Bind(destination, "serial:explore", "v1")
				sourceRef, destinationRef := gates.ReferenceForSession(source, "source"), gates.ReferenceForSession(destination, "destination")
				remember := func(ref identitygate.Reference) {
					for i := range 5 {
						gates.RecordFirstContentDecodeObservation(ref, explicitDecodeObservation(explorationMemoryModel, float64(10+i), int64(i+1), clock.Now()), 80, clock.Now())
					}
				}
				if priorSourceRates {
					remember(sourceRef)
				}
				if newerClear {
					remember(destinationRef)
					clock.Advance(time.Second)
				}
				gates.RecordFirstContentDecodeObservation(sourceRef, explicitDecodeObservation(explorationMemoryModel, 40, 6, clock.Now()), 80, clock.Now())
				if !newerClear {
					clock.Advance(time.Second)
					remember(destinationRef)
				}
				// A newer outcome must not change the clear's rate chronology.
				clock.Advance(time.Second)
				gates.RecordFirstContentExplorationOutcome("source", explorationMemoryModel, false)
				gates.Bind(source, "serial:explore", "v1")
				view := gates.ViewForSession(nil, "source").Exploration(explorationMemoryModel, clock.Now())
				if !view.Suppressed || view.RememberedSlow(80) == newerClear {
					t.Fatalf("migration lost independent backoff/rate chronology: %+v", view)
				}
			})
		}
	}
}

func TestExplorationMigrationOutcomeDoesNotRenewOldRates(t *testing.T) {
	gates, clock := newExplorationMemoryDirectory()
	source, destination := gates.Attach("source"), gates.Attach("destination")
	gates.Bind(source, "sekey:explore", "v1")
	gates.Bind(destination, "serial:explore", "v1")
	for i := range 5 {
		gates.RecordFirstContentDecodeObservation(gates.ReferenceForSession(source, "source"), explicitDecodeObservation(explorationMemoryModel, float64(10+i), int64(i+1), clock.Now()), 80, clock.Now())
	}
	clock.Advance(time.Second)
	for i := range 5 {
		gates.RecordFirstContentDecodeObservation(gates.ReferenceForSession(destination, "destination"), explicitDecodeObservation(explorationMemoryModel, float64(30+i), int64(i+1), clock.Now()), 80, clock.Now())
	}
	clock.Advance(time.Second)
	gates.RecordFirstContentExplorationOutcome("source", explorationMemoryModel, false)
	gates.Bind(source, "serial:explore", "v1")
	view := gates.ViewForSession(nil, "source").Exploration(explorationMemoryModel, clock.Now())
	if !view.Suppressed || view.DecodeMedian != 32 {
		t.Fatalf("newer failure overwrote newer rate evidence: %+v", view)
	}
}

func TestExplorationHeartbeatReconnectDoesNotCorroborateOneObservation(t *testing.T) {
	for _, explicit := range []bool{false, true} {
		t.Run(fmt.Sprintf("explicit_%v", explicit), func(t *testing.T) {
			gates := identitygate.New(testLogger(), nil)
			throughput := production.NewTPSRegistry()
			for range 50 {
				throughput.Record(explorationBackoffModel, testRegisterMessage().Hardware.ChipFamily, 80)
			}
			r := production.NewWithDependencies(testLogger(), production.Dependencies{IdentityGates: gates, Throughput: throughput})
			for i := range 6 {
				id := fmt.Sprintf("reconnect-%d", i)
				p := attestSchedulerProvider(t, r, id, explorationBackoffModel, "EXPLORE-RECONNECT", 0)
				capacity := p.BackendCapacitySnapshot()
				slot := &capacity.Slots[0]
				zero, initialized, prefill := int64(0), true, 1200.0
				slot.ObservedDecodeTPS = 10
				slot.Telemetry = &protocol.SlotTelemetry{QueuedPrefillTokens: &zero, PartialPrefillRows: &zero,
					EWMAInitialized: &initialized, IsolatedPrefillTPS: &prefill}
				if explicit {
					slot.PerformanceMeasurements = localRateMeasurements(prefill, 10)
				}
				if !r.Heartbeat(id, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: capacity}) {
					t.Fatal("valid reconnect heartbeat rejected")
				}
				view := gates.ViewForSession(nil, id).Exploration(explorationBackoffModel, time.Now())
				if view.DecodeSamples != 1 || view.RememberedSlow(80) {
					t.Fatalf("reconnect %d duplicated one producer sample: %+v", i, view)
				}
				r.Disconnect(id)
			}
		})
	}
}

func TestExplorationMemoryProducerWatermarksSurviveClearAndSharedIdentity(t *testing.T) {
	gates, clock := newExplorationMemoryDirectory()
	first, second := gates.Attach("first"), gates.Attach("second")
	gates.Bind(first, "serial:shared", "v1")
	gates.Bind(second, "serial:shared", "v1")
	firstRef, secondRef := gates.ReferenceForSession(first, "first"), gates.ReferenceForSession(second, "second")
	old := clock.Now()
	for i := range 5 {
		observation := explicitDecodeObservation(explorationMemoryModel, 10, int64(i+1), old)
		gates.RecordFirstContentDecodeObservation(firstRef, observation, 80, clock.Now())
		gates.RecordFirstContentDecodeObservation(secondRef, observation, 80, clock.Now())
	}
	view := gates.ViewForSession(first, "first")
	if got := view.Exploration(explorationMemoryModel, clock.Now()); got.DecodeSamples != 5 || !got.RememberedSlow(80) {
		t.Fatalf("shared sessions did not count exactly five producer observations: %+v", got)
	}
	clock.Advance(time.Second)
	gates.RecordFirstContentDecodeObservation(secondRef, explicitDecodeObservation(explorationMemoryModel, 40, 6, clock.Now()), 80, clock.Now())
	clock.Advance(time.Second)
	for range 5 {
		gates.RecordFirstContentDecodeObservation(firstRef, explicitDecodeObservation(explorationMemoryModel, 10, 5, old), 80, clock.Now())
	}
	if got := view.Exploration(explorationMemoryModel, clock.Now()); got != (identitygate.ExplorationView{}) {
		t.Fatalf("clear discarded producer watermarks: %+v", got)
	}
	// A genuinely newer observation, even at the same rate, still counts.
	gates.RecordFirstContentDecodeObservation(firstRef, explicitDecodeObservation(explorationMemoryModel, 10, 7, clock.Now()), 80, clock.Now())
	if got := view.Exploration(explorationMemoryModel, clock.Now()).DecodeSamples; got != 1 {
		t.Fatalf("new count after recovery: got %d samples, want 1", got)
	}
}

func TestExplorationMemoryOrdersSamplesAndClearsByObservationTime(t *testing.T) {
	gates, clock := newExplorationMemoryDirectory()
	session := gates.Attach("session")
	ref := gates.ReferenceForSession(session, "session")
	old := clock.Now()
	clock.Advance(time.Second)
	gates.RecordFirstContentDecodeObservation(ref, explicitDecodeObservation(explorationMemoryModel, 40, 1, clock.Now()), 80, clock.Now())
	clock.Advance(time.Second)
	for i := range 5 {
		late := explicitDecodeObservation(explorationMemoryModel, 10, int64(i+1), old)
		late.Epoch = "late-slow"
		gates.RecordFirstContentDecodeObservation(ref, late, 80, clock.Now())
	}
	view := gates.ViewForSession(session, "session")
	if got := view.Exploration(explorationMemoryModel, clock.Now()); got.DecodeSamples != 0 {
		t.Fatalf("late older slow samples undid newer healthy clear: %+v", got)
	}
	for i := range 5 {
		gates.RecordFirstContentDecodeObservation(ref, explicitDecodeObservation(explorationMemoryModel, 10, int64(i+2), clock.Now()), 80, clock.Now())
	}
	lateHealthy := explicitDecodeObservation(explorationMemoryModel, 40, 1, old)
	lateHealthy.Epoch = "late-healthy"
	clock.Advance(time.Second)
	gates.RecordFirstContentDecodeObservation(ref, lateHealthy, 80, clock.Now())
	if got := view.Exploration(explorationMemoryModel, clock.Now()); got.DecodeSamples != 5 || !got.RememberedSlow(80) {
		t.Fatalf("late older healthy report cleared newer slow evidence: %+v", got)
	}
}

func TestExplorationMemoryAlternatingEpochsAndLegacyRatesDoNotReplay(t *testing.T) {
	for _, explicit := range []bool{false, true} {
		t.Run(fmt.Sprintf("explicit_%v", explicit), func(t *testing.T) {
			gates, clock := newExplorationMemoryDirectory()
			session := gates.Attach("session")
			ref := gates.ReferenceForSession(session, "session")
			for i := range 12 {
				observation := measurements.DecodeObservation{Model: explorationMemoryModel, Rate: float64(10 + i%2)}
				if explicit {
					observation = explicitDecodeObservation(explorationMemoryModel, 10, 1, clock.Now())
					observation.Epoch = fmt.Sprintf("epoch-%d", i%2)
				}
				gates.RecordFirstContentDecodeObservation(ref, observation, 80, clock.Now())
				clock.Advance(time.Second)
			}
			if got := gates.ViewForSession(session, "session").Exploration(explorationMemoryModel, clock.Now()); got.DecodeSamples != 2 || got.RememberedSlow(80) {
				t.Fatalf("alternating producer replays corroborated slow memory: %+v", got)
			}
		})
	}
}

func TestExplorationMemorySaturatedProvenanceIsConservative(t *testing.T) {
	gates, clock := newExplorationMemoryDirectory()
	session := gates.Attach("session")
	ref := gates.ReferenceForSession(session, "session")
	old := clock.Now()
	for i := range 8 {
		observation := explicitDecodeObservation(explorationMemoryModel, 10, 1, old)
		observation.Epoch = fmt.Sprintf("epoch-%d", i)
		gates.RecordFirstContentDecodeObservation(ref, observation, 80, clock.Now())
	}
	clock.Advance(time.Second)
	healthy := explicitDecodeObservation(explorationMemoryModel, 40, 1, clock.Now())
	healthy.Epoch = "healthy-overflow"
	gates.RecordFirstContentDecodeObservation(ref, healthy, 80, clock.Now())
	view := gates.ViewForSession(session, "session")
	if got := view.Exploration(explorationMemoryModel, clock.Now()).DecodeSamples; got != 0 {
		t.Fatalf("watermark capacity prevented fresh recovery: %d samples", got)
	}
	clock.Advance(time.Second)
	for i := range 16 {
		replay := explicitDecodeObservation(explorationMemoryModel, 10, 1, clock.Now())
		replay.Epoch = fmt.Sprintf("epoch-%d", i)
		gates.RecordFirstContentDecodeObservation(ref, replay, 80, clock.Now())
	}
	if got := view.Exploration(explorationMemoryModel, clock.Now()).DecodeSamples; got != 0 {
		t.Fatalf("forgotten/unknown producers manufactured corroboration: %d samples", got)
	}
	newSample := explicitDecodeObservation(explorationMemoryModel, 10, 2, clock.Now())
	newSample.Epoch = "epoch-0"
	gates.RecordFirstContentDecodeObservation(ref, newSample, 80, clock.Now())
	// The healthy event is not in the full watermark set, but its timestamp
	// still prevents its replay from clearing a genuinely newer sample.
	gates.RecordFirstContentDecodeObservation(ref, healthy, 80, clock.Now())
	if got := view.Exploration(explorationMemoryModel, clock.Now()).DecodeSamples; got != 1 {
		t.Fatalf("known producer advance or old overflow clear was mishandled: %d samples", got)
	}
}

func TestExplorationMemoryMergePreservesOmittedProducerFence(t *testing.T) {
	gates, clock := newExplorationMemoryDirectory()
	source, destination := gates.Attach("source"), gates.Attach("destination")
	gates.Bind(source, "sekey:explore", "v1")
	gates.Bind(destination, "serial:explore", "v1")
	destinationRef := gates.ReferenceForSession(destination, "destination")
	for i := range 8 {
		observation := explicitDecodeObservation(explorationMemoryModel, 10, 1, clock.Now())
		observation.Epoch = fmt.Sprintf("destination-%d", i)
		gates.RecordFirstContentDecodeObservation(destinationRef, observation, 80, clock.Now())
	}
	clock.Advance(time.Hour)
	sourceRef := gates.ReferenceForSession(source, "source")
	for i := range 8 {
		observation := explicitDecodeObservation(explorationMemoryModel, 10, 1, clock.Now())
		observation.Epoch = fmt.Sprintf("source-%d", i)
		gates.RecordFirstContentDecodeObservation(sourceRef, observation, 80, clock.Now())
	}
	healthy := explicitDecodeObservation(explorationMemoryModel, 40, 2, clock.Now())
	healthy.Epoch = "source-0"
	gates.RecordFirstContentDecodeObservation(sourceRef, healthy, 80, clock.Now())
	gates.Bind(source, "serial:explore", "v1")
	// Destination marks expire first. Source marks omitted by the bounded
	// merge must still be fenced, even when there is now space for them.
	clock.Advance(5 * time.Hour)
	gates.Maintain(clock.Now())
	for i := range 8 {
		replay := explicitDecodeObservation(explorationMemoryModel, 10, 1, clock.Now())
		replay.Epoch = fmt.Sprintf("source-%d", i)
		gates.RecordFirstContentDecodeObservation(sourceRef, replay, 80, clock.Now())
	}
	if got := gates.ViewForSession(source, "source").Exploration(explorationMemoryModel, clock.Now()).DecodeSamples; got != 0 {
		t.Fatalf("expired destination slots forgot merged source watermarks: %d samples", got)
	}
	clock.Advance(time.Hour)
	gates.Maintain(clock.Now())
	fresh := explicitDecodeObservation(explorationMemoryModel, 10, 2, clock.Now())
	fresh.Epoch = "source-1"
	gates.RecordFirstContentDecodeObservation(sourceRef, fresh, 80, clock.Now())
	if got := gates.ViewForSession(source, "source").Exploration(explorationMemoryModel, clock.Now()).DecodeSamples; got != 1 {
		t.Fatalf("expired fence did not permit genuinely fresh evidence: %d samples", got)
	}
}

func TestExplorationMemoryProvenanceExpiresWithoutInvalidReportsAdvancingIt(t *testing.T) {
	gates, clock := newExplorationMemoryDirectory()
	session := gates.Attach("session")
	ref := gates.ReferenceForSession(session, "session")
	first := explicitDecodeObservation(explorationMemoryModel, 10, 1, clock.Now())
	gates.RecordFirstContentDecodeObservation(ref, first, 80, clock.Now())
	for _, corrupt := range []func(*measurements.DecodeObservation){
		func(o *measurements.DecodeObservation) { o.Epoch = "" },
		func(o *measurements.DecodeObservation) { o.SampleCount = 0 },
		func(o *measurements.DecodeObservation) { o.ObservedAfter = time.Time{} },
		func(o *measurements.DecodeObservation) { o.ObservedAfter = clock.Now().Add(time.Second) },
	} {
		invalid := explicitDecodeObservation(explorationMemoryModel, 10, 99, clock.Now())
		corrupt(&invalid)
		gates.RecordFirstContentDecodeObservation(ref, invalid, 80, clock.Now())
	}
	gates.RecordFirstContentDecodeObservation(ref, explicitDecodeObservation(explorationMemoryModel, 11, 2, clock.Now()), 80, clock.Now())
	view := gates.ViewForSession(session, "session")
	if got := view.Exploration(explorationMemoryModel, clock.Now()).DecodeSamples; got != 2 {
		t.Fatalf("invalid report advanced producer watermark: %d samples", got)
	}
	clock.Advance(6 * time.Hour)
	gates.Maintain(clock.Now())
	gates.RecordFirstContentDecodeObservation(ref, first, 80, clock.Now())
	if got := view.Exploration(explorationMemoryModel, clock.Now()).DecodeSamples; got != 0 {
		t.Fatalf("expired producer sample reappeared after watermark TTL: %d samples", got)
	}
	gates.RecordFirstContentDecodeObservation(ref, explicitDecodeObservation(explorationMemoryModel, 12, 3, clock.Now()), 80, clock.Now())
	if got := view.Exploration(explorationMemoryModel, clock.Now()).DecodeSamples; got != 1 {
		t.Fatalf("fresh evidence after TTL did not count: %d samples", got)
	}
}
