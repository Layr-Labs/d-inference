package registry

import (
	"fmt"
	"os"
	"strconv"
	"time"

	"github.com/eigeninference/d-inference/coordinator/env"
)

// WarmingConfig holds tuning knobs for predictive model warming.
// All durations use Go time units when parsed from environment (e.g. "60s", "5m").
type WarmingConfig struct {
	// Enabled turns on the predictive warming planner.
	Enabled bool
	// PlannerInterval is how often the warming planner re-evaluates demand.
	PlannerInterval time.Duration
	// ForecastHorizon is how far ahead demand is predicted.
	ForecastHorizon time.Duration
	// TargetUtilization is the desired ratio of a provider's capacity to consume
	// before warming another provider (e.g., 0.7 for 70%).
	TargetUtilization float64
	// MaxLoadsPerModelPerTick limits how many concurrent load_model commands are
	// sent for a single model in one planner tick (anti-thundering-herd).
	MaxLoadsPerModelPerTick int
	// MinWarmTime is the minimum time a provider-model pair stays warm before
	// the coordinator considers allowing idle unload.
	MinWarmTime time.Duration
	// EWMA10sWeight, EWMA60sWeight, EWMA5mWeight tune the recent-demand signal.
	EWMA10sWeight, EWMA60sWeight, EWMA5mWeight float64
	// HistoricalWeight tunes the historical baseline signal.
	HistoricalWeight float64
}

// Config holds registry-level configuration.
type Config struct {
	MinTrustLevel string // overrides default trust level (empty = use default)
	Warming       WarmingConfig
}

// DefaultWarmingConfig returns the default predictive warming configuration.
func DefaultWarmingConfig() WarmingConfig {
	return WarmingConfig{
		Enabled:                 false,
		PlannerInterval:         1 * time.Second,
		ForecastHorizon:         60 * time.Second,
		TargetUtilization:       0.7,
		MaxLoadsPerModelPerTick: 3,
		MinWarmTime:             5 * time.Minute,
		EWMA10sWeight:           0.6,
		EWMA60sWeight:           0.4,
		EWMA5mWeight:            0.2,
		HistoricalWeight:        0.5,
	}
}

// ReadConfig reads registry configuration from environment variables.
func ReadConfig() Config {
	wc := DefaultWarmingConfig()
	wc.Enabled = os.Getenv(env.EnvPrefix+"_PREDICTIVE_WARMING_ENABLED") == "true"
	if v := os.Getenv(env.EnvPrefix + "_WARMING_PLANNER_INTERVAL"); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			wc.PlannerInterval = d
		}
	}
	if v := os.Getenv(env.EnvPrefix + "_WARMING_FORECAST_HORIZON"); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			wc.ForecastHorizon = d
		}
	}
	if v := os.Getenv(env.EnvPrefix + "_WARMING_TARGET_UTILIZATION"); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil {
			wc.TargetUtilization = f
		}
	}
	if v := os.Getenv(env.EnvPrefix + "_WARMING_MAX_LOADS_PER_TICK"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			wc.MaxLoadsPerModelPerTick = n
		}
	}
	if v := os.Getenv(env.EnvPrefix + "_WARMING_MIN_WARM_TIME"); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			wc.MinWarmTime = d
		}
	}
	return Config{
		MinTrustLevel: os.Getenv(env.EnvPrefix + "_MIN_TRUST"),
		Warming:       wc,
	}
}

// Check validates the configuration.
// An empty MinTrustLevel is valid and means "use the default".
func (c Config) Check() error {
	if c.MinTrustLevel == "" {
		return nil
	}
	// trustRank returns -1 for unrecognized trust levels.
	if trustRank(TrustLevel(c.MinTrustLevel)) < 0 {
		return fmt.Errorf("registry: invalid MinTrustLevel %q (valid: %q, %q, %q)",
			c.MinTrustLevel, TrustNone, TrustSelfSigned, TrustHardware)
	}
	return nil
}
