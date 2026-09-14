package main

import (
	"context"
	"log/slog"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
)

func startBackgroundLoops(ctx context.Context, reg *registry.Registry, srv *api.Server, logger *slog.Logger) {
	// Start background eviction of stale providers.
	reg.StartEvictionLoop(ctx, 90*time.Second)

	// Push gauge values to DogStatsD periodically.
	go srv.StartDDGaugeLoop(ctx)
	srv.StartProfilerLoops(ctx)

	// Reclaim expired read-cache entries periodically (bounds memory growth).
	go srv.StartReadCacheJanitor(ctx)

	// Background goroutines own the /v1/stats and /v1/network/totals cache
	// entries; handlers only read them.
	srv.StartCacheRefreshers(ctx)

	// Flag any model decoding far below its active-param/hardware class (W8 —
	// auto-detects the gemma-dense decode bug). Spawns its own panic-safe loop.
	srv.StartThroughputAnomalyDetector(ctx)

	// Base-rewards settlement (only when enabled).
	if br := srv.BaseRewards(); br != nil {
		saferun.Go(logger, "base_rewards_settlement", func() { br.Run(ctx) })
	}

	// Stripe payout reconciler: heals connected accounts stuck on a legacy
	// manual payout schedule and alerts on withdrawals stuck in "transferred".
	// No-op when Stripe Connect isn't configured. Spawns its own panic-safe loop.
	srv.StartStripePayoutReconciler(ctx)
	srv.StartGlobalPayoutReconciler(ctx)
}
