// Package telemetry provides server-side utilities for the coordinator's
// telemetry pipeline. Today it holds only the retention loop; Phase 2 extends
// this with an internal emitter for capturing coordinator-side events.
package telemetry

import (
	"context"
	"log/slog"
	"time"

	"github.com/eigeninference/coordinator/internal/store"
)

// RunRetentionLoop periodically deletes telemetry_events older than maxAge.
// Blocks until ctx is cancelled. Safe to call as a goroutine.
func RunRetentionLoop(ctx context.Context, st store.Store, logger *slog.Logger, interval, maxAge time.Duration) {
	if interval <= 0 {
		interval = time.Hour
	}
	if maxAge <= 0 {
		maxAge = 14 * 24 * time.Hour
	}
	t := time.NewTicker(interval)
	defer t.Stop()

	// Run once on startup so a freshly-deployed coordinator can reclaim space
	// from any stale backlog before the first tick.
	pruneOnce(ctx, st, logger, maxAge)

	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			pruneOnce(ctx, st, logger, maxAge)
		}
	}
}

func pruneOnce(ctx context.Context, st store.Store, logger *slog.Logger, maxAge time.Duration) {
	cutoff := time.Now().Add(-maxAge)
	removed, err := st.DeleteTelemetryEventsOlderThan(ctx, cutoff)
	if err != nil {
		logger.Warn("telemetry retention prune failed", "error", err)
		return
	}
	if removed > 0 {
		logger.Info("telemetry retention pruned", "removed", removed, "cutoff", cutoff.UTC())
	}
}
