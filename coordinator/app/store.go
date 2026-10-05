package app

import (
	"context"
	"log/slog"
	"os"
	"time"

	"github.com/eigeninference/d-inference/coordinator/config"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
	memorystore "github.com/eigeninference/d-inference/coordinator/store/memory"
	postgresstore "github.com/eigeninference/d-inference/coordinator/store/postgres"
)

func openStore(ctx context.Context, cfg config.AppConfig, logger *slog.Logger) (store.Store, func()) {
	adminKey := cfg.AdminKey
	closeStore := func() {}
	var st store.Store
	if cfg.StoreConfig.DatabaseURL != "" {
		pgStore, err := postgresstore.NewPostgres(ctx, cfg.StoreConfig)
		if err != nil {
			logger.Error("failed to connect to PostgreSQL", "error", err)
			os.Exit(1)
		}
		closeStore = pgStore.Close
		st = pgStore
		logger.Info("using PostgreSQL store")

		// If an admin key is set, seed it in the database.
		if adminKey != "" {
			if err := pgStore.SeedKey(adminKey); err != nil {
				logger.Warn("failed to seed admin key (may already exist)", "error", err)
			}
		}
	} else {
		if !cfg.StoreConfig.AllowMemoryStore {
			logger.Error("EIGENINFERENCE_DATABASE_URL is not set and EIGENINFERENCE_ALLOW_MEMORY_STORE is not \"true\" — refusing to start with non-durable store")
			os.Exit(1)
		}

		memStore := memorystore.NewMemory(store.Config{AdminKey: adminKey})
		st = memStore
		logger.Warn("using in-memory store — billing state will not survive restart (set EIGENINFERENCE_DATABASE_URL for production)")

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

	// Reconcile provider sessions left open by a previous coordinator process
	// (durable uptime history). Best-effort + time-bounded — neither an error nor
	// a slow/unresponsive DB must block startup. Only sessions whose last
	// heartbeat is older than the staleness fence are closed, so a blue-green
	// cutover over the shared DB does NOT truncate sessions still live (and being
	// touched every heartbeat) on the old instance — only genuinely-orphaned rows
	// from a dead prior process age past the fence and get closed.
	func() {
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
	}()

	return st, closeStore
}
