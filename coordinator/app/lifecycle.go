package app

import (
	"context"
	"log/slog"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/api/operations"
	"github.com/eigeninference/d-inference/coordinator/api/readcache"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
)

func startBackgroundLoops(ctx context.Context, srv *api.Server, reg *registry.Registry, cache *readcache.Cache, logger *slog.Logger) {
	// Start background eviction of stale providers.
	reg.StartEvictionLoop(ctx, registry.DefaultProviderHeartbeatTimeout)

	// Push gauge values to DogStatsD periodically.
	go srv.StartDDGaugeLoop(ctx)
	go srv.StartWarmPoolTelemetryLoop(ctx)
	srv.StartProfilerLoops(ctx)

	// Reclaim expired read-cache entries periodically (bounds memory growth).
	go func() {
		saferun.Go(logger, "model_token_promotion_maintenance", func() { srv.Inference().RunModelTokenMaintenance(ctx) })
		cache.RunJanitor(ctx, time.Minute)
	}()

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
	// Account erasure: scrub requests whose grace period has ended.
	srv.StartAccountErasureLoop(ctx)
	// Deliver the erasure outbox: Stripe deletions and the erasure_log record.
	srv.StartErasureOutboxLoop(ctx)

}

func drainAndStop(srv *api.Server, reg *registry.Registry, httpServer *http.Server, promptSidecar *promptcontract.Supervisor, cancel, persistCancel context.CancelFunc, logger *slog.Logger) {
	// Enter drain mode first so /readyz and /health immediately report not-ready,
	// the capacity feed stops advertising, and new inference requests get
	// 429+Retry-After (DAR-327 Phase 1).
	srv.SetDraining(true)

	// DAR-327 merge note: when Phase 3 (#396) lands, srv.BroadcastGoingAway()
	// belongs HERE — right after SetDraining(true) and BEFORE cancel() /
	// WaitForInflightZero — so providers begin draining+reconnecting while we wait
	// for in-flight HTTP to finish. The canonical combined shutdown order is:
	// SetDraining → BroadcastGoingAway → cancel → WaitForInflightZero → Shutdown.
	cancel() // Stop the eviction loop.
	promptSidecar.Close()

	// Wait for already-admitted in-flight requests to finish before shutting the
	// HTTP server down. Streaming responses can run well past the 15s Shutdown
	// deadline, so we poll Inflight() until it reaches 0 or EIGENINFERENCE_DRAIN_GRACE
	// (default 10m) elapses — whichever comes first — instead of cutting them off.
	// We never block forever: the grace context bounds the wait, and the hard
	// Shutdown deadline below is the final backstop.
	grace := operations.DrainGraceFromEnv()
	graceCtx, graceCancel := context.WithTimeout(context.Background(), grace)
	if srv.WaitForInflightZero(graceCtx) {
		logger.Info("drain complete; in-flight requests finished", "grace", grace.String())
	} else {
		logger.Warn("drain grace elapsed; forcing shutdown with requests still in flight",
			"grace", grace.String(), "inflight", srv.Inflight())
	}
	graceCancel()

	// Hard backstop: even after the grace wait, give Shutdown a bounded deadline so
	// a stuck connection can't block process exit forever.
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer shutdownCancel()
	if err := httpServer.Shutdown(shutdownCtx); err != nil {
		logger.Error("shutdown error", "error", err)
	}

	// Provider sockets are hijacked, so Shutdown neither closes nor waits on
	// them and they keep producing receipts and heartbeats; close them and
	// join their handlers, then take the final write-behind of the cache
	// routing indexes with no producer left behind it. The periodic flush
	// loop stays alive until here.
	closeCtx, closeCancel := context.WithTimeout(context.Background(), 5*time.Second)
	joined := srv.CloseProviderConnections(closeCtx)
	closeCancel()
	// Stop the periodic loop and join it before deciding on the final flush:
	// a restore retry in flight has then either made the persister ready
	// (so the flush below writes everything) or been cancelled, and no flush
	// of the loop's own can run behind the final one.
	persistCancel()
	loopCtx, loopCancel := context.WithTimeout(context.Background(), 15*time.Second)
	if !reg.WaitCacheRoutingPersistence(loopCtx) {
		logger.Warn("cache routing persistence loop still running at the shutdown deadline; the final flush proceeds")
	}
	loopCancel()
	warnedNotReady := false
	finalFlush := func() {
		flushCtx, flushCancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer flushCancel()
		if s := reg.CacheRoutingPersistenceStatus(); s.Enabled && !s.Ready {
			if !warnedNotReady {
				logger.Warn("cache routing persistence never established its key generation this run; the final flush writes nothing")
				warnedNotReady = true
			}
		} else if err := reg.FlushCacheRoutingState(flushCtx); err != nil {
			logger.Warn("final cache routing persistence flush failed", "error", err)
		}
	}
	finalFlush()
	if !joined {
		// A handler still running can mark evidence behind that flush (a
		// read-error close and the deferred teardown take seconds). Give the
		// join the rest of the budget, then flush again.
		joinCtx, joinCancel := context.WithTimeout(context.Background(), 10*time.Second)
		joined = srv.WaitProviderHandlers(joinCtx)
		joinCancel()
		finalFlush()
		if !joined {
			logger.Warn("provider socket handlers still running at exit; cache routing evidence they mark from here is lost")
		}
	}

	logger.Info("coordinator stopped")
}
