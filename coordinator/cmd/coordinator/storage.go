package main

import (
	"context"
	"log/slog"
	"time"

	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func startMemoryStorePruner(ctx context.Context, memStore *store.MemoryStore, logger *slog.Logger) {
	pruneInterval := 15 * time.Minute
	pruneMax := store.DefaultPruneMaxEntries
	saferun.Go(logger, "memory_store_pruner", func() {
		ticker := time.NewTicker(pruneInterval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				memStore.Prune(pruneMax)
			}
		}
	})
}

func withStoreCache(st store.Store, logger *slog.Logger) store.Store {
	// Read-through cache for the per-request user and model-registry lookups
	// (one Postgres round trip each, 4-5 per inference request). Wraps both
	// backends so dev/test and prod behave identically. Invalidation is
	// in-process -- correct because this single process serves every admin and
	// publish mutation; the TTLs only bound staleness from out-of-band DB edits.
	cacheCfg := store.DefaultCacheConfig()
	st = store.NewCached(st, cacheCfg)
	logger.Info("store read-through cache enabled",
		"user_ttl", cacheCfg.UserTTL, "model_ttl", cacheCfg.ModelTTL, "negative_ttl", cacheCfg.NegativeTTL,
		"max_users", cacheCfg.MaxUsers, "max_models", cacheCfg.MaxModels)
	return st
}

func reconcileProviderSessions(ctx context.Context, st store.Store, logger *slog.Logger) {
	// Reconcile provider sessions left open by a previous coordinator process
	// (durable uptime history). Best-effort + time-bounded — neither an error nor
	// a slow/unresponsive DB must block startup. Only sessions whose last
	// heartbeat is older than the staleness fence are closed, so a blue-green
	// cutover over the shared DB does NOT truncate sessions still live (and being
	// touched every heartbeat) on the old instance — only genuinely-orphaned rows
	// from a dead prior process age past the fence and get closed.
	rctx, rcancel := context.WithTimeout(ctx, 10*time.Second)
	defer rcancel()
	// 3 min comfortably exceeds the 30s heartbeat and 90s eviction window, so
	// any session live on another instance stays fresh; orphans do not.
	staleBefore := time.Now().Add(-3 * time.Minute)
	if n, err := st.CloseOpenProviderSessions(rctx, staleBefore); err != nil {
		logger.Warn("failed to reconcile open provider sessions", "error", err)
	} else if n > 0 {
		logger.Info("reconciled orphaned provider sessions", "closed", n)
	}
}
