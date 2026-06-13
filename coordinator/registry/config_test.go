package registry

import (
	"os"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/env"
)

// TestDefaultWarmingConfig documents the default predictive-warming tuning
// values referenced in AGENTS.md.
func TestDefaultWarmingConfig(t *testing.T) {
	cfg := DefaultWarmingConfig()
	if cfg.Enabled {
		t.Error("predictive warming is disabled by default")
	}
	if cfg.PlannerInterval != 1*time.Second {
		t.Errorf("PlannerInterval=%v, want 1s", cfg.PlannerInterval)
	}
	if cfg.ForecastHorizon != 60*time.Second {
		t.Errorf("ForecastHorizon=%v, want 60s", cfg.ForecastHorizon)
	}
	if cfg.TargetUtilization != 0.7 {
		t.Errorf("TargetUtilization=%v, want 0.7", cfg.TargetUtilization)
	}
	if cfg.MaxLoadsPerModelPerTick != 3 {
		t.Errorf("MaxLoadsPerModelPerTick=%d, want 3", cfg.MaxLoadsPerModelPerTick)
	}
	if cfg.MinWarmTime != 5*time.Minute {
		t.Errorf("MinWarmTime=%v, want 5m", cfg.MinWarmTime)
	}
}

// TestReadConfigPredictiveWarmingEnabled documents the feature flag that
// enables predictive warming.
func TestReadConfigPredictiveWarmingEnabled(t *testing.T) {
	key := env.EnvPrefix + "_PREDICTIVE_WARMING_ENABLED"
	t.Setenv(key, "true")
	defer os.Unsetenv(key)

	cfg := ReadConfig()
	if !cfg.Warming.Enabled {
		t.Error("predictive warming should be enabled when the env var is true")
	}
}
