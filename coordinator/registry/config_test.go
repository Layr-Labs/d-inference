package registry

import (
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
