package liveness

import (
	"context"
	"log/slog"
	"time"

	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Retention defaults — tunable via env in cmd/coordinator/main.go.
const (
	defaultRetentionInterval = time.Hour
	defaultRetentionDays     = 28
	defaultRetentionBatch    = 10000
)

// DefaultRetentionInterval is the default time between retention prune runs.
func DefaultRetentionInterval() time.Duration { return defaultRetentionInterval }

// DefaultRetentionDays is the default age threshold (in days) for raw
// heartbeats. Rows older than this are deleted by the retention loop.
func DefaultRetentionDays() int { return defaultRetentionDays }

// DefaultRetentionBatch is the default per-DELETE batch size. Tuned to keep
// WAL pressure / replication lag bounded and allow autovacuum to keep up.
func DefaultRetentionBatch() int { return defaultRetentionBatch }

// RetentionConfig parameterizes the retention loop.
type RetentionConfig struct {
	Interval time.Duration // how often to run the prune loop
	Window   time.Duration // delete heartbeats older than now-Window
	Batch    int           // rows deleted per DELETE statement
}

func (c RetentionConfig) withDefaults() RetentionConfig {
	if c.Interval <= 0 {
		c.Interval = defaultRetentionInterval
	}
	if c.Window <= 0 {
		c.Window = defaultRetentionDays * 24 * time.Hour
	}
	if c.Batch <= 0 {
		c.Batch = defaultRetentionBatch
	}
	return c
}

// StartRetentionLoop runs a periodic prune of provider_heartbeats. Mirrors
// registry.StartEvictionLoop's saferun.Go + ticker pattern so a panic can't
// take down the coordinator. Exits when ctx is cancelled.
//
// The actual DELETE is batched: the loop calls DeleteHeartbeatsBefore in a
// drain loop until either a single call returns 0 (caught up) or the per-run
// time budget (cfg.Interval - 5s) is exhausted. This keeps WAL pressure
// bounded and lets autovacuum keep pace.
//
// `count` is the metrics callback (nil-safe). It receives one of:
//   - "liveness_retention_rows_total"   incremented by rows actually deleted
//   - "liveness_retention_runs_total"   incremented once per scheduled run
//   - "liveness_retention_errors_total" incremented on DB error
func StartRetentionLoop(ctx context.Context, s store.Store, logger *slog.Logger, count CounterFn, cfg RetentionConfig) {
	cfg = cfg.withDefaults()
	if logger == nil {
		logger = slog.Default()
	}
	logger = logger.With("component", "liveness.retention")

	saferun.Go(logger, "liveness.retentionLoop", func() {
		// Run once promptly on boot so a long-stopped coordinator catches up
		// before waiting for the first tick.
		runRetention(ctx, s, logger, count, cfg)

		ticker := time.NewTicker(cfg.Interval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				runRetention(ctx, s, logger, count, cfg)
			}
		}
	})
}

func runRetention(ctx context.Context, s store.Store, logger *slog.Logger, count CounterFn, cfg RetentionConfig) {
	if count != nil {
		count("liveness_retention_runs_total", 1)
	}

	// Reserve 5s of headroom before the next tick so a slow DB can't make
	// retention runs overlap or starve other work.
	budget := cfg.Interval - 5*time.Second
	if budget < 5*time.Second {
		budget = 5 * time.Second
	}
	deadline := time.Now().Add(budget)
	before := time.Now().Add(-cfg.Window)

	var total int64
	for time.Now().Before(deadline) {
		if ctx.Err() != nil {
			return
		}
		deleted, err := s.DeleteHeartbeatsBefore(ctx, before, cfg.Batch)
		if err != nil {
			if count != nil {
				count("liveness_retention_errors_total", 1)
			}
			logger.Warn("retention delete failed", "error", err, "total_so_far", total)
			return
		}
		if deleted == 0 {
			break
		}
		total += deleted
		if count != nil {
			count("liveness_retention_rows_total", deleted)
		}
	}
	if total > 0 {
		logger.Info("retention prune complete",
			"rows_deleted", total,
			"window_days", int(cfg.Window/(24*time.Hour)))
	}
}
