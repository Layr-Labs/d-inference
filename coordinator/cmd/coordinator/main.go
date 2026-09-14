// Command coordinator runs the Darkbloom (EigenInference) coordinator control plane.
//
// The coordinator is the central routing and trust layer in the Darkbloom network.
// It accepts provider WebSocket connections, verifies their Secure Enclave
// attestations, and routes OpenAI-compatible HTTP requests from consumers
// to appropriate providers based on model availability and trust level.
//
// Deployment: The coordinator runs in a GCP Confidential VM (AMD SEV)
// with hardware-encrypted memory. Consumer traffic arrives over HTTPS/TLS.
// The coordinator can read requests for routing purposes but never logs
// prompt content.
//
// Configuration is defined per-package and composed into config.AppConfig.
// See coordinator/config/ for the full schema.
//
// Graceful shutdown: The coordinator handles SIGINT/SIGTERM, enters drain mode,
// stops the eviction loop, waits for in-flight requests to finish (up to
// EIGENINFERENCE_DRAIN_GRACE, default 10m), then drains connections with a hard
// 15-second http.Server.Shutdown deadline as the final backstop.
package main

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/config"
	"github.com/eigeninference/d-inference/coordinator/datadog"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/telemetry"
	ddtracer "gopkg.in/DataDog/dd-trace-go.v1/ddtrace/tracer"
)

func main() {
	// Structured JSON logging. When Datadog is active, we wrap the handler
	// with trace context injection so logs correlate with APM traces.
	var slogHandler slog.Handler = slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	})
	if os.Getenv("DD_API_KEY") != "" || os.Getenv("DD_AGENT_HOST") != "" {
		slogHandler = datadog.NewTraceHandler(slogHandler)
	}
	logger := slog.New(slogHandler)
	slog.SetDefault(logger)

	if len(os.Args) > 1 {
		if err := runMaintenanceCommand(os.Args[1:]); err != nil {
			logger.Error("coordinator maintenance command failed", "error", err)
			os.Exit(1)
		}
		return
	}

	// Read all configuration from environment variables.
	cfg := config.ReadAppConfig()
	if err := cfg.Check(); err != nil {
		logger.Error("invalid configuration", "error", err)
		os.Exit(1)
	}

	adminKey := cfg.AdminKey
	if adminKey == "" {
		logger.Warn("EIGENINFERENCE_ADMIN_KEY is not set — no pre-seeded API key available")
	}

	// Create core components.
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	var st store.Store
	if cfg.StoreConfig.DatabaseURL != "" {
		pgStore, err := store.NewPostgres(ctx, cfg.StoreConfig)
		if err != nil {
			logger.Error("failed to connect to PostgreSQL", "error", err)
			os.Exit(1)
		}
		defer pgStore.Close()
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

		memStore := store.NewMemory(store.Config{AdminKey: adminKey})
		st = memStore
		logger.Warn("using in-memory store — billing state will not survive restart (set EIGENINFERENCE_DATABASE_URL for production)")

		startMemoryStorePruner(ctx, memStore, logger)
	}

	st = withStoreCache(st, logger)
	reconcileProviderSessions(ctx, st, logger)

	reg := registry.New(logger)

	configureRegistry(reg, cfg.RegistryCfg, logger)

	stopWarmPool := reg.StartWarmPoolController(ctx, cfg.RegistryCfg.WarmPool)
	defer stopWarmPool()
	if cfg.RegistryCfg.WarmPool.Enabled {
		logger.Info("warm-pool controller enabled", "observe_only", cfg.RegistryCfg.WarmPool.ObserveOnly, "interval", cfg.RegistryCfg.WarmPool.Interval.String())
	}

	serverCfg := serverConfig(&cfg, logger)
	srv := api.NewServer(reg, st, serverCfg, logger)
	promptProvisioner := configurePromptArtifacts(ctx, srv, cfg.PromptSidecar, logger)

	// Stop the routing-telemetry sink's worker pool on shutdown. Deferred so it
	// runs after the HTTP server has drained (no in-flight request can still be
	// submitting telemetry); Close is idempotent and never blocks on in-flight
	// writes, so it cannot stall shutdown.
	defer srv.Close()

	configureRateLimits(ctx, srv, &cfg, logger)

	// Coordinator self-telemetry emitter.
	telemetryEmitter := telemetry.NewEmitter(logger, srv.Metrics(), telemetry.CoordinatorVersion)
	srv.SetEmitter(telemetryEmitter)

	// --- Datadog APM + DogStatsD + Logs API ---
	ddCfg := cfg.DatadogConfig
	if ddCfg.APIKey != "" || os.Getenv("DD_AGENT_HOST") != "" {
		ddtracer.Start(
			ddtracer.WithService(ddCfg.Service),
			ddtracer.WithEnv(ddCfg.Env),
		)
		defer ddtracer.Stop()
		logger.Info("datadog APM tracer started", "service", ddCfg.Service, "env", ddCfg.Env)

		ddClient, err := datadog.NewClient(ddCfg, logger)
		if err != nil {
			logger.Warn("datadog client init failed (continuing without DD)", "error", err)
		} else {
			srv.SetDatadog(ddClient)
			telemetryEmitter.SetDatadog(ddClient)
			defer ddClient.Close()
			logger.Info("datadog integration enabled",
				"statsd_addr", ddCfg.StatsdAddr,
				"logs_api", ddCfg.APIKey != "",
				"site", ddCfg.Site,
			)
		}
	}

	configureReleasePolicy(srv, reg, logger)
	configureAdmission(srv, logger)
	configureRuntimeManifest(srv, logger)
	configureModelDeadlines(logger)
	configureProfiling(logger)
	configureAccounts(srv, reg, st, &cfg, logger)
	configureProviderTrust(ctx, srv, cfg.MDMConfig, logger)
	startBackgroundLoops(ctx, reg, srv, logger)

	httpServer := newHTTPServer(cfg.ServerConfig.Port, srv.Handler())

	promptSidecar := startPromptSidecar(ctx, srv, promptProvisioner, cfg.PromptSidecar, logger)

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

	// Stop admitting inference first. /readyz reports 503; /health stays live.
	srv.SetDraining(true)

	cancel() // Stop the eviction loop.
	promptSidecar.Close()

	// Wait for already-admitted in-flight requests to finish before shutting the
	// HTTP server down. Streaming responses can run well past the 15s Shutdown
	// deadline, so we poll Inflight() until it reaches 0 or EIGENINFERENCE_DRAIN_GRACE
	// (default 10m) elapses — whichever comes first — instead of cutting them off.
	// We never block forever: the grace context bounds the wait, and the hard
	// Shutdown deadline below is the final backstop.
	grace := api.DrainGraceFromEnv()
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

	logger.Info("coordinator stopped")
}
