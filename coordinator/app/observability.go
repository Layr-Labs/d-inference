package app

import (
	"log/slog"
	"os"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/config"
	"github.com/eigeninference/d-inference/coordinator/datadog"
	"github.com/eigeninference/d-inference/coordinator/telemetry"

	ddtracer "gopkg.in/DataDog/dd-trace-go.v1/ddtrace/tracer"
)

func configureObservability(cfg config.AppConfig, srv *api.Server, logger *slog.Logger) func() {
	stopTracer, closeClient := func() {}, func() {}
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
		stopTracer = ddtracer.Stop
		logger.Info("datadog APM tracer started", "service", ddCfg.Service, "env", ddCfg.Env)

		ddClient, err := datadog.NewClient(ddCfg, logger)
		if err != nil {
			logger.Warn("datadog client init failed (continuing without DD)", "error", err)
		} else {
			srv.SetDatadog(ddClient)
			telemetryEmitter.SetDatadog(ddClient)
			closeClient = func() { ddClient.Close() }
			logger.Info("datadog integration enabled",
				"statsd_addr", ddCfg.StatsdAddr,
				"logs_api", ddCfg.APIKey != "",
				"site", ddCfg.Site,
			)
		}
	}

	return func() { closeClient(); stopTracer() }
}
