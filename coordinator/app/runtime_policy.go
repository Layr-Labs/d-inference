package app

import (
	"log/slog"
	"os"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/api/releases"
	"github.com/eigeninference/d-inference/coordinator/modelpolicy"
)

func configureRuntimePolicy(srv *api.Server, logger *slog.Logger) {
	// Load runtime template manifest from environment variable (optional override).
	// When configured, providers whose template hashes don't match are excluded from
	// routing (but not disconnected) and receive feedback about mismatches.
	// Python/runtime hashes are deprecated — only template hashes (e.g. mlx_metallib) are checked.
	if templateHashes := os.Getenv("EIGENINFERENCE_KNOWN_TEMPLATE_HASHES"); templateHashes != "" {
		// The manifest is a set per template name: repeating a name
		// (mlx_metallib=<a>,mlx_metallib=<b>) accepts every listed hash.
		manifest := releases.NewRuntimeManifest()
		for _, pair := range strings.Split(templateHashes, ",") {
			parts := strings.SplitN(strings.TrimSpace(pair), "=", 2)
			if len(parts) == 2 {
				manifest.AddTemplateHash(parts[0], parts[1])
			}
		}
		srv.SetRuntimeManifest(manifest)
		logger.Info("runtime manifest configured from env",
			"template_hashes", len(manifest.TemplateHashes),
		)
	}

	// Exact-model first-content deadline base overrides
	// ("<model>=<upstream_ms>,...", 0/"off" removes an entry so the model
	// falls back to the global base). The built-in table (Qwen3-VL 5s/4s) can
	// only tighten the global base — during the 2026-09-01 incident that
	// hardcoding killed ~47% of vision traffic with no operator recourse.
	if v := os.Getenv("EIGENINFERENCE_MODEL_FIRST_CONTENT_BASES"); v != "" {
		if replaced, removed := modelpolicy.SetFirstContentBasesFromEnv(v); replaced+removed > 0 {
			logger.Info("exact-model first-content deadline bases overridden via EIGENINFERENCE_MODEL_FIRST_CONTENT_BASES",
				"replaced", replaced, "removed", removed, "value", v)
		} else {
			logger.Warn("invalid EIGENINFERENCE_MODEL_FIRST_CONTENT_BASES; using built-in table", "value", v)
		}
	}
	if v := os.Getenv("EIGENINFERENCE_MODEL_FIRST_CONTENT_SLAS"); v != "" {
		if err := modelpolicy.SetFirstContentSLAsFromEnv(v); err != nil {
			logger.Error("invalid model first-content SLA configuration", "error", err)
			os.Exit(1)
		}
	}

	// Optional pprof listener on a DEDICATED private mux/port — never the
	// public mux. The 2026-09-01 collapse was diagnosed blind because the
	// binary shipped without pprof (GET /debug/pprof/ = 404). Unset = nothing
	// listens.
	if addr := os.Getenv("EIGENINFERENCE_PPROF_ADDR"); addr != "" {
		if ln, err := startPprofListener(addr); err != nil {
			logger.Error("pprof listener failed to start", "addr", addr, "error", err)
		} else {
			enableContentionProfiling()
			logger.Warn("pprof debug listener ENABLED via EIGENINFERENCE_PPROF_ADDR — profiling data is sensitive; keep this address private (bind loopback / firewall it)",
				"addr", ln.Addr().String())
		}
	}

}
