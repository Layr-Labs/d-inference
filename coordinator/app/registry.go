package app

import (
	"context"
	"log/slog"
	"os"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/config"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func configureRegistry(ctx context.Context, cfg config.AppConfig, logger *slog.Logger) (*registry.Registry, func()) {
	reg := registry.New(logger)

	// Set minimum trust level for routing.
	if cfg.RegistryCfg.MinTrustLevel != "" {
		reg.MinTrustLevel = registry.TrustLevel(cfg.RegistryCfg.MinTrustLevel)
		logger.Info("minimum trust level override", "level", cfg.RegistryCfg.MinTrustLevel)
	}

	// Dedicated-box routing: model families (matched as case-insensitive
	// substrings of the resolved build id) that may ONLY route to providers
	// whose entire advertised catalog is that family — isolating an unstable
	// model (e.g. Gemma 4) onto dedicated machines so it never contends with
	// other models. Default: "gemma-4". Override with a comma-separated list, or
	// set the value to empty / "none" to disable. With no dedicated box
	// available, a request for such a model sheds to OpenRouter as a transient
	// 429 (not 503).
	dedicatedModels := []string{"gemma-4"}
	if v, ok := os.LookupEnv("EIGENINFERENCE_DEDICATED_MODELS"); ok {
		if strings.EqualFold(strings.TrimSpace(v), "none") {
			dedicatedModels = nil
		} else {
			dedicatedModels = registry.ParseDedicatedModels(v)
		}
	}
	reg.SetDedicatedModels(dedicatedModels)
	if len(dedicatedModels) > 0 {
		logger.Info("dedicated-model routing ENABLED", "patterns", strings.Join(dedicatedModels, ","))
	} else {
		logger.Info("dedicated-model routing disabled")
	}

	// Quality-concurrency admission cap: tighten the flat per-provider concurrency
	// cap (24) to each model's quality_concurrency × overcommit, computed from the
	// provider's static single-stream decode rate. Stops slow, saturated models
	// (e.g. Gemma) from over-admitting onto a few boxes and collapsing decode TPS;
	// near-no-op for fast/over-provisioned models. Reuses the warm-pool decode
	// floor + fallback so admission and warm-pool planning share the same math.
	reg.SetQualityConcurrencyCap(
		cfg.RegistryCfg.QualityCap.Enabled,
		cfg.RegistryCfg.QualityCap.Overcommit,
		cfg.RegistryCfg.WarmPool.DecodeFloorTPS,
		cfg.RegistryCfg.WarmPool.FallbackQualityConcurrency,
	)
	logger.Info("quality-concurrency cap",
		"enabled", cfg.RegistryCfg.QualityCap.Enabled,
		"overcommit", reg.QualityCapOvercommit(),
		"decode_floor_tps", cfg.RegistryCfg.WarmPool.DecodeFloorTPS,
	)

	if err := reg.ConfigureCacheRouting(cfg.RegistryCfg.CacheRouting); err != nil {
		logger.Error("cache routing configuration rejected", "error", err)
		os.Exit(1)
	}
	cacheRoutingCfg := reg.CacheRoutingConfigSnapshot()
	logger.Info("provider-confirmed cache routing configured",
		"mode", cacheRoutingCfg.Mode,
		"artifact_allowlist_configured", cacheRoutingCfg.AllowedArtifacts != nil,
		"artifact_allowlist_count", len(cacheRoutingCfg.AllowedArtifacts),
		"activation_percent", cacheRoutingCfg.ActivationPct,
		"max_plan_qps", cacheRoutingCfg.MaxPlanQPS,
		"ttl", cacheRoutingCfg.TTL.String(),
		"max_holders", cacheRoutingCfg.MaxHolders,
		"max_discount_ms", cacheRoutingCfg.MaxDiscountMs,
		"max_cost_fraction", cacheRoutingCfg.MaxCostFraction,
		"first_sight_min_tokens", cacheRoutingCfg.FirstSightMinTokens,
	)
	stopWarmPool := reg.StartWarmPoolController(ctx, cfg.RegistryCfg.WarmPool)
	stopAutopilot := reg.StartAutopilotController(ctx, cfg.RegistryCfg.Autopilot)
	if cfg.RegistryCfg.WarmPool.Enabled {
		logger.Info("warm-pool controller enabled", "observe_only", cfg.RegistryCfg.WarmPool.ObserveOnly, "interval", cfg.RegistryCfg.WarmPool.Interval.String())
	}

	return reg, func() { stopAutopilot(); stopWarmPool() }
}
