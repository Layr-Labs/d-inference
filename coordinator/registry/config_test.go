package registry

import (
	"encoding/base64"
	"math"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/env"
)

func clearWarmPoolEnv(t *testing.T) {
	t.Helper()
	keys := []string{
		"WARM_POOL_ENABLED",
		"WARM_POOL_OBSERVE_ONLY",
		"WARM_POOL_INTERVAL",
		"WARM_POOL_MIN_DWELL",
		"WARM_POOL_QUEUE_AGE_THRESHOLD",
		"WARM_POOL_CAPACITY_REJECT_THRESHOLD",
		"WARM_POOL_WARM_SATURATION_THRESHOLD",
		"WARM_POOL_TTFT_MISS_THRESHOLD",
		"WARM_POOL_SPECULATIVE_START_THRESHOLD",
		"WARM_POOL_SPECULATIVE_WIN_THRESHOLD",
		"WARM_POOL_COLD_DISPATCH_THRESHOLD",
		"WARM_POOL_LOAD_DURATION_THRESHOLD",
		"WARM_POOL_MIN_WARM",
		"WARM_POOL_MAX_LOADS_PER_TICK",
		"WARM_POOL_MAX_GLOBAL_PENDING_LOADS",
	}
	for _, key := range keys {
		t.Setenv(env.EnvPrefix+"_"+key, "")
	}
}

func TestReadConfigWarmPoolDefaultsActive(t *testing.T) {
	clearWarmPoolEnv(t)

	cfg := ReadConfig().WarmPool
	if !cfg.Enabled {
		t.Fatal("warm pool should default to enabled")
	}
	if cfg.ObserveOnly {
		t.Fatal("warm pool should default to active, not observe-only")
	}
	if cfg.Interval != 10*time.Second {
		t.Fatalf("Interval = %v, want 10s", cfg.Interval)
	}
	if cfg.QueueAgeThreshold != 0 {
		t.Fatalf("QueueAgeThreshold = %v, want 0", cfg.QueueAgeThreshold)
	}
	if cfg.MaxLoadsPerTick != 4 {
		t.Fatalf("MaxLoadsPerTick = %d, want 4", cfg.MaxLoadsPerTick)
	}
	if cfg.MaxGlobalPendingLoads != 16 {
		t.Fatalf("MaxGlobalPendingLoads = %d, want 16", cfg.MaxGlobalPendingLoads)
	}
}

func TestReadConfigWarmPoolMinWarmByModel(t *testing.T) {
	clearWarmPoolEnv(t)
	t.Setenv(env.EnvPrefix+"_WARM_POOL_MIN_WARM", "gpt-oss-20b=4, bad, gemma=0, other=-1, qwen=2")

	got := ReadConfig().WarmPool.MinWarmByModel
	if got["gpt-oss-20b"] != 4 {
		t.Fatalf("gpt-oss floor = %d, want 4", got["gpt-oss-20b"])
	}
	if got["qwen"] != 2 {
		t.Fatalf("qwen floor = %d, want 2", got["qwen"])
	}
	if _, ok := got["gemma"]; ok {
		t.Fatal("zero min-warm entry should be ignored")
	}
	if _, ok := got["other"]; ok {
		t.Fatal("negative min-warm entry should be ignored")
	}
}

func TestReadConfigWarmPoolCanBeDisabled(t *testing.T) {
	clearWarmPoolEnv(t)
	t.Setenv(env.EnvPrefix+"_WARM_POOL_ENABLED", "false")
	t.Setenv(env.EnvPrefix+"_WARM_POOL_OBSERVE_ONLY", "true")

	cfg := ReadConfig().WarmPool
	if cfg.Enabled {
		t.Fatal("warm pool enabled despite explicit false")
	}
	if !cfg.ObserveOnly {
		t.Fatal("warm pool observe-only override was not honored")
	}
}

func TestCacheRoutingConfigFailsClosedUnlessOff(t *testing.T) {
	base := CacheRoutingConfig{
		ActivationPct: 100, TTL: 10 * time.Minute, MaxHolders: 4,
		MaxDiscountMs: 1000, MaxCostFraction: .35,
	}
	base.Mode = CacheRoutingOff
	if err := base.Check(); err != nil {
		t.Fatalf("off mode required a key: %v", err)
	}
	for _, mode := range []string{CacheRoutingOn} {
		cfg := base
		cfg.Mode = mode
		if err := cfg.Check(); err == nil {
			t.Fatalf("mode %q accepted missing key", mode)
		}
		cfg.MasterKey = "not-a-valid-key"
		if err := cfg.Check(); err == nil {
			t.Fatalf("mode %q accepted malformed key", mode)
		}
		cfg.MasterKey = base64.RawURLEncoding.EncodeToString(
			[]byte("0123456789abcdef0123456789abcdef"))
		if err := cfg.Check(); err != nil {
			t.Fatalf("mode %q rejected valid key: %v", mode, err)
		}
	}
}

func TestReadConfigCacheRoutingDefaultsOff(t *testing.T) {
	for _, suffix := range []string{"MODE", "PERCENT", "MAX_PLAN_QPS", "TTL", "MAX_HOLDERS", "MAX_DISCOUNT_MS", "MAX_COST_FRACTION", "CACHE_MASTER_KEY"} {
		key := env.EnvPrefix + "_CACHE_ROUTING_" + suffix
		if suffix == "CACHE_MASTER_KEY" {
			key = env.EnvPrefix + "_CACHE_MASTER_KEY"
		}
		t.Setenv(key, "")
	}
	cfg := ReadConfig().CacheRouting
	if cfg.Mode != "" || cfg.ActivationPct != 100 || cfg.MaxPlanQPS != 0 ||
		cfg.TTL != 10*time.Minute || cfg.MaxHolders != 4 ||
		cfg.MaxDiscountMs != 1000 || cfg.MaxCostFraction != .35 {
		t.Fatalf("cache routing defaults = %+v", cfg)
	}
}

func TestReadConfigCacheRoutingActivationOverrides(t *testing.T) {
	t.Setenv(env.EnvPrefix+"_CACHE_ROUTING_PERCENT", "1")
	t.Setenv(env.EnvPrefix+"_CACHE_ROUTING_MAX_PLAN_QPS", "1")
	cfg := ReadConfig().CacheRouting
	if cfg.ActivationPct != 1 || cfg.MaxPlanQPS != 1 {
		t.Fatalf("cache routing activation overrides=%+v", cfg)
	}
}

func TestReadConfigCacheRoutingRejectsMalformedActivationLimits(t *testing.T) {
	for _, tc := range []struct {
		key   string
		value func(CacheRoutingConfig) float64
	}{
		{key: env.EnvPrefix + "_CACHE_ROUTING_PERCENT", value: func(c CacheRoutingConfig) float64 { return c.ActivationPct }},
		{key: env.EnvPrefix + "_CACHE_ROUTING_MAX_PLAN_QPS", value: func(c CacheRoutingConfig) float64 { return c.MaxPlanQPS }},
	} {
		t.Run(tc.key, func(t *testing.T) {
			t.Setenv(tc.key, "not-a-number")
			cfg := ReadConfig().CacheRouting
			if !math.IsNaN(tc.value(cfg)) || cfg.Check() == nil {
				t.Fatalf("malformed safety limit %s silently fell back: %+v", tc.key, cfg)
			}
		})
	}
}

func TestCacheRoutingConfigRejectsNonFiniteDiscounts(t *testing.T) {
	base := CacheRoutingConfig{
		Mode: CacheRoutingOff, ActivationPct: 100, TTL: time.Minute, MaxHolders: 4,
		MaxDiscountMs: 1000, MaxCostFraction: .35,
	}
	for _, tc := range []struct {
		name       string
		discountMs float64
		fraction   float64
	}{
		{name: "discount_nan", discountMs: math.NaN(), fraction: .35},
		{name: "discount_pos_inf", discountMs: math.Inf(1), fraction: .35},
		{name: "discount_neg_inf", discountMs: math.Inf(-1), fraction: .35},
		{name: "fraction_nan", discountMs: 1000, fraction: math.NaN()},
		{name: "fraction_pos_inf", discountMs: 1000, fraction: math.Inf(1)},
		{name: "fraction_neg_inf", discountMs: 1000, fraction: math.Inf(-1)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cfg := base
			cfg.MaxDiscountMs = tc.discountMs
			cfg.MaxCostFraction = tc.fraction
			if err := cfg.Check(); err == nil {
				t.Fatalf("accepted non-finite cache routing config: %+v", cfg)
			}
		})
	}
}

func TestCacheRoutingConfigValidatesOperationalActivation(t *testing.T) {
	base := CacheRoutingConfig{
		Mode: CacheRoutingOff, ActivationPct: 100, TTL: time.Minute,
		MaxHolders: 4, MaxDiscountMs: 1000, MaxCostFraction: .35,
	}
	for _, tc := range []struct {
		name    string
		percent float64
		qps     float64
	}{
		{name: "zero_percent", percent: 0},
		{name: "negative_percent", percent: -1},
		{name: "percent_over_100", percent: 100.01},
		{name: "percent_nan", percent: math.NaN()},
		{name: "negative_qps", percent: 100, qps: -1},
		{name: "qps_over_limit", percent: 100, qps: maxCacheRoutingPlanQPS + 1},
		{name: "qps_infinite", percent: 100, qps: math.Inf(1)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cfg := base
			cfg.ActivationPct = tc.percent
			cfg.MaxPlanQPS = tc.qps
			if err := cfg.Check(); err == nil {
				t.Fatalf("accepted invalid activation config: %+v", cfg)
			}
		})
	}
	base.ActivationPct = 1
	base.MaxPlanQPS = 1
	if err := base.Check(); err != nil {
		t.Fatalf("rejected safe 1%%/1 QPS activation: %v", err)
	}
}

func TestConfigureCacheRoutingRejectsExplicitZeroPercent(t *testing.T) {
	reg := New(testLogger())
	err := reg.ConfigureCacheRouting(CacheRoutingConfig{
		Mode: CacheRoutingOff, ActivationPct: 0,
		TTL: time.Minute, MaxHolders: 4,
		MaxDiscountMs: 1000, MaxCostFraction: .35,
	})
	if err == nil {
		t.Fatal("ConfigureCacheRouting rewrote explicit zero percent instead of rejecting it")
	}
}
