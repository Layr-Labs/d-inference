package liveness

import (
	"context"
	"log/slog"
	"time"

	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Hourly rollup defaults — tunable via env in cmd/coordinator/main.go.
const (
	defaultHourlyInterval = 5 * time.Minute
	defaultHourlyLookback = 2 * time.Hour
)

// DefaultHourlyInterval is the default cadence of hourly rollup runs.
// Matches the features rollup so the two share a ticker tier.
func DefaultHourlyInterval() time.Duration { return defaultHourlyInterval }

// DefaultHourlyLookback is the default window of raw heartbeats considered
// by each rollup run. 2h covers both the in-progress current hour and the
// just-completed previous hour, which lets out-of-order or late-arriving
// heartbeats catch the right bucket on the next tick.
func DefaultHourlyLookback() time.Duration { return defaultHourlyLookback }

// HourlyConfig parameterizes the rollup worker.
type HourlyConfig struct {
	Interval time.Duration
	Lookback time.Duration
}

func (c HourlyConfig) withDefaults() HourlyConfig {
	if c.Interval <= 0 {
		c.Interval = defaultHourlyInterval
	}
	if c.Lookback <= 0 {
		c.Lookback = defaultHourlyLookback
	}
	return c
}

// HourlyQuery is the subset of store.Store the rollup needs. Decoupled
// from the store package so test fakes can implement just this method.
type HourlyQuery interface {
	RollupHeartbeatsHourly(ctx context.Context, since time.Time) (int64, error)
}

// StartHourlyLoop runs the hourly heartbeat rollup periodically. Like the
// features and retention loops, it runs once eagerly on boot, then on
// cfg.Interval.
//
// `count` is the metrics callback (nil-safe). Counters emitted:
//   - "liveness_hourly_runs_total"      incremented per scheduled run
//   - "liveness_hourly_rows_total"      incremented by # of (provider, hour) cells written per run
//   - "liveness_hourly_errors_total"    incremented on DB error
func StartHourlyLoop(ctx context.Context, q HourlyQuery, logger *slog.Logger, count CounterFn, cfg HourlyConfig) {
	cfg = cfg.withDefaults()
	if logger == nil {
		logger = slog.Default()
	}
	logger = logger.With("component", "liveness.hourly")

	saferun.Go(logger, "liveness.hourlyLoop", func() {
		runHourly(ctx, q, logger, count, cfg)

		ticker := time.NewTicker(cfg.Interval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				runHourly(ctx, q, logger, count, cfg)
			}
		}
	})
}

func runHourly(ctx context.Context, q HourlyQuery, logger *slog.Logger, count CounterFn, cfg HourlyConfig) {
	if count != nil {
		count("liveness_hourly_runs_total", 1)
	}

	since := time.Now().Add(-cfg.Lookback)
	written, err := q.RollupHeartbeatsHourly(ctx, since)
	if err != nil {
		if count != nil {
			count("liveness_hourly_errors_total", 1)
		}
		logger.Warn("rollup hourly failed", "error", err)
		return
	}
	if count != nil && written > 0 {
		count("liveness_hourly_rows_total", written)
	}
	if written > 0 {
		logger.Info("hourly rollup complete", "rows", written)
	}
}

// Compile-time assertions that the in-tree store backends satisfy
// HourlyQuery. (No-op at runtime.)
var (
	_ HourlyQuery = (*store.MemoryStore)(nil)
	_ HourlyQuery = (*store.PostgresStore)(nil)
)
