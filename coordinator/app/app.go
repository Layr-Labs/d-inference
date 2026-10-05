// Package app assembles and runs the coordinator service graph.
package app

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/api/readcache"
	"github.com/eigeninference/d-inference/coordinator/config"
	startup "github.com/eigeninference/d-inference/coordinator/internal/startup"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
)

// Run serves the coordinator using the validated application configuration.
func Run(cfg config.AppConfig, logger *slog.Logger) {
	adminKey := cfg.AdminKey
	if adminKey == "" {
		logger.Warn("EIGENINFERENCE_ADMIN_KEY is not set — no pre-seeded API key available")
	}

	// Create core components.
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	st, closeStore := openStore(ctx, cfg, logger)
	defer closeStore()

	reg, stopRegistry := configureRegistry(ctx, cfg, logger)
	defer stopRegistry()

	// Provider/consumer IP geolocation (api.newProviderGeoResolverFromEnv, invoked
	// from NewServer) reads two optional env vars:
	//   - EIGENINFERENCE_TRUST_GEO_HEADERS=1 — trust CF/Vercel geo headers from a
	//     trusted reverse proxy instead of calling ip-api.com.
	//   - EIGENINFERENCE_IPAPI_KEY — ip-api.com PRO key (SECRET; inject via KMS /
	//     Secret Manager, never commit). When set, geo lookups use the unmetered
	//     https://pro.ip-api.com endpoint; unset falls back to the free, 45 req/min
	//     http://ip-api.com endpoint (graceful, so dev without a key still works).
	// Remote media resolution (mediafetch) is read and validated as part of
	// AppConfig; hand the validated value to the server instead of letting
	// NewServer re-read the environment.
	serverCfg := cfg.ServerConfig
	serverCfg.DurableTrustReuse = cfg.StoreConfig.DatabaseURL != ""
	serverCfg.MediaFetch = &cfg.MediaFetchCfg
	// LIVE first-content deadline base — distinct from the shadow evaluator's
	// base below. Validate and bind it to this Server instance before startup;
	// production sets 9000ms, while an unset/invalid value keeps the intentional
	// 5000ms ordinary-unit default. Exact model policy may tighten this base but
	// never loosen a lower operator value. Every request adds 1ms per prompt token.
	if v := os.Getenv("EIGENINFERENCE_TTFT_LIVE_DEADLINE_BASE_MS"); v != "" {
		if base, ok := startup.ValidateTTFTDeadlineBaseMs(v); ok {
			serverCfg.FirstContentDeadlineBase = time.Duration(base) * time.Millisecond
			logger.Warn("LIVE TTFT deadline base OVERRIDDEN via EIGENINFERENCE_TTFT_LIVE_DEADLINE_BASE_MS (changes the HARD_REJECT cutoff)", "base_ms", base)
		} else {
			logger.Warn("invalid or out-of-range EIGENINFERENCE_TTFT_LIVE_DEADLINE_BASE_MS; keeping default 5000",
				"value", v, "min_ms", startup.MinTTFTDeadlineBaseMs, "max_ms", startup.MaxTTFTDeadlineBaseMs)
		}
	}
	ledger, cache := payments.NewLedger(st), readcache.New()
	runtime := api.NewRuntime(api.RuntimeDependencies{
		Registry: reg, Store: st, Ledger: ledger, ReadCache: cache, Logger: logger,
	}, serverCfg)
	srv := runtime.Server
	// The server handed the store to the registry; restore the durable cache
	// routing indexes now so the holder index is not empty after a restart.
	// The write-behind loop keeps running through the drain (the main ctx is
	// cancelled before it) and is stopped and joined right before the final
	// flush, which runs once the HTTP server and the provider sockets are
	// down.
	persistCtx, persistCancel := context.WithCancel(context.Background())
	defer persistCancel()
	if cfg.RegistryCfg.CacheRouting.Persist {
		if status, err := reg.StartCacheRoutingPersistence(persistCtx); err != nil {
			logger.Warn("cache routing persistence restore failed; the index starts empty and nothing is written until a retry succeeds", "error", err)
		} else if status.Enabled {
			logger.Info("cache routing persistence restored",
				"holders_pending", status.PendingHolders, "demand_entries", status.RestoredDemand,
				"key_rotated", status.KeyRotated)
		}
	}
	promptProvisioner := preparePromptArtifacts(ctx, cfg, srv, logger)
	// Stop the routing-telemetry sink's worker pool on shutdown. Deferred so it
	// runs after the HTTP server has drained (no in-flight request can still be
	// submitting telemetry); Close is idempotent and never blocks on in-flight
	// writes, so it cannot stall shutdown.
	defer srv.Close()

	configureRateLimits(ctx, cfg, srv, logger)

	stopObservability := configureObservability(cfg, runtime.Observation, logger)
	defer stopObservability()

	configureReleasePolicy(srv, reg, logger)

	configureRouting(srv, logger)

	configureRuntimePolicy(srv, logger)

	configureBillingAndTrust(ctx, cfg, srv, reg, st, ledger, logger)

	startBackgroundLoops(ctx, srv, reg, cache, logger)

	// HTTP server with graceful shutdown.
	httpServer := &http.Server{
		Addr:    ":" + cfg.ServerConfig.Port,
		Handler: srv.Handler(),
		// ReadHeaderTimeout bounds the request-header read phase independently of
		// the body, closing the slow-header (Slowloris) DoS window: a client that
		// trickles or never finishes its header block is dropped at 5s instead of
		// tying up a connection/goroutine. Kept shorter than ReadTimeout so header
		// hardening doesn't constrain legitimate (larger) request bodies.
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      0, // SSE streaming requires no write timeout
		IdleTimeout:       120 * time.Second,
		// MaxHeaderBytes caps per-connection header memory at 64 KB (Go's default
		// is 1 MB), bounding what an attacker can force the server to buffer for
		// headers and rejecting abusive oversized-header requests early.
		MaxHeaderBytes: 64 << 10,
	}
	promptSidecar := promptcontract.NewSupervisor(cfg.PromptSidecar)
	srv.Inference().SetPromptSupervisor(promptSidecar)
	if cfg.PromptSidecar.Enabled {
		srv.Inference().SetPromptContractClient(promptSidecar.Client())
	}
	promptSidecar.Start(ctx)
	if cfg.PromptSidecar.Enabled && promptProvisioner != nil {
		promptPreloader, err := promptcontract.NewPreloadController(
			promptProvisioner,
			promptSidecar,
			promptcontract.PreloadControllerConfig{},
		)
		if err != nil {
			logger.Error("prompt contract preload gate disabled", "error", err)
		} else {
			srv.Inference().SetPromptPreloadController(promptPreloader)
			promptPreloader.Start(ctx)
		}
	}

	// Start listening.
	go func() {
		logger.Info("coordinator starting", "port", cfg.ServerConfig.Port, "admin_key_set", adminKey != "")
		if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			logger.Error("server failed", "error", err)
			os.Exit(1)
		}
	}()

	// Wait for interrupt signal.
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	sig := <-sigCh
	logger.Info("shutting down", "signal", sig.String())

	drainAndStop(srv, reg, httpServer, promptSidecar, cancel, persistCancel, logger)
}
