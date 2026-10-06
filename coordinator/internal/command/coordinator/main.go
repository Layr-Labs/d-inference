// Package coordinator implements the coordinator command lifecycle.
package coordinator

import (
	"log/slog"
	"os"

	"github.com/eigeninference/d-inference/coordinator/app"
	"github.com/eigeninference/d-inference/coordinator/config"
	"github.com/eigeninference/d-inference/coordinator/datadog"
)

func Main() {
	var handler slog.Handler = slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo})
	if os.Getenv("DD_API_KEY") != "" || os.Getenv("DD_AGENT_HOST") != "" {
		handler = datadog.NewTraceHandler(handler)
	}
	logger := slog.New(handler)
	slog.SetDefault(logger)
	if len(os.Args) > 1 {
		if err := Maintenance(os.Args[1:]); err != nil {
			logger.Error("coordinator maintenance command failed", "error", err)
			os.Exit(1)
		}
		return
	}
	cfg := config.ReadAppConfig()
	if err := cfg.Check(); err != nil {
		logger.Error("invalid configuration", "error", err)
		os.Exit(1)
	}
	app.Run(cfg, logger)
}
