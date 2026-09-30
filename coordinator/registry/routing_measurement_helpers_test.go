package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// setFreshIdleFirstContentTelemetry supplies qualified idle evidence to tests
// of deadline gates. Ingestion/freshness lifecycle is tested through actual
// heartbeat frames in first_content_forecast_test.go.
func setFreshIdleFirstContentTelemetry(p *Provider, rate float64) {
	p.mu.Lock()
	defer p.mu.Unlock()
	now := time.Now()
	p.CapacityAcceptedAt = now
	p.PrefillTPS = rate
	slot := &p.BackendCapacity.Slots[0]
	slot.State = "idle"
	slot.ObservedPrefillTPS = rate
	slot.ObservedDecodeTPS = 100
	slot.Telemetry = &protocol.SlotTelemetry{
		QueuedPrefillTokens: new(int64), PartialPrefillRows: new(int64),
		IsolatedPrefillTPS: &rate, EWMAInitialized: new(bool),
	}
	*slot.Telemetry.EWMAInitialized = true
	p.firstContentMeasurements = map[string]firstContentMeasurement{slot.Model: {rate: rate, observedAfter: now, decodeObservedAfter: now}}
}
