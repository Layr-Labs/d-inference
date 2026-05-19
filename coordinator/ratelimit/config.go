package ratelimit

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/env"
)

// Config controls the limiter's behavior. Zero values fall back to defaults.
type Config struct {
	RPS        float64
	Burst      int
	IdleEvict  time.Duration
	PruneEvery time.Duration
}

// ConfigPair holds separate Configs for inference and financial endpoints.
type ConfigPair struct {
	Inference Config
	Financial Config
}

// ReadConfig reads both rate limiter configs from environment variables.
func ReadConfig() ConfigPair {
	return ConfigPair{
		Inference: Config{
			RPS:   env.EnvFloat(env.EnvPrefix+"_RATE_LIMIT_RPS", DefaultRPS),
			Burst: env.EnvInt(env.EnvPrefix+"_RATE_LIMIT_BURST", DefaultBurst),
		},
		Financial: Config{
			RPS:   env.EnvFloat(env.EnvPrefix+"_FINANCIAL_RATE_LIMIT_RPS", 0.2),
			Burst: env.EnvInt(env.EnvPrefix+"_FINANCIAL_RATE_LIMIT_BURST", 3),
		},
	}
}

// Check validates the config. Currently a no-op.
func (c Config) Check() error { return nil }

// Check is a no-op for ConfigPair.
func (cp ConfigPair) Check() error { return nil }
