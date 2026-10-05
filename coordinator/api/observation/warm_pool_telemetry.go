package observation

import (
	"context"
	"time"

	fleet "github.com/eigeninference/d-inference/coordinator/internal/observation/fleet"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Poll more frequently than the default 30-second controller interval so the
// emitter observes periodic ticks without depending on startup ordering. The
// snapshot timestamp suppresses duplicates and bounds volume when the
// controller is idle.
const warmPoolTelemetryPollInterval = 15 * time.Second

// StartWarmPoolTelemetryLoop forwards the latest distinct warm-pool planning
// snapshot to the coordinator telemetry emitter. The registry keeps only the
// newest tick, so this is a sampled state feed rather than an event ledger.
func (s *Owner) StartWarmPoolTelemetryLoop(ctx context.Context) {
	if s == nil || s.registry == nil || s.Emitter() == nil || s.Datadog() == nil {
		return
	}

	var lastEmittedAt time.Time
	emitLatest := func() {
		snaps, at := s.registry.LatestWarmPoolSnapshots()
		if len(snaps) == 0 || at.IsZero() || !at.After(lastEmittedAt) {
			return
		}
		for _, snap := range snaps {
			s.Emit(ctx, protocol.SeverityInfo, protocol.KindCustom, "warm_pool_tick",
				fleet.WarmPoolFields(snap))
		}
		lastEmittedAt = at
	}

	emitLatest()
	ticker := time.NewTicker(warmPoolTelemetryPollInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			emitLatest()
		}
	}
}
