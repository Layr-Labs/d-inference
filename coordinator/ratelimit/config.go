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

// TokenConfig holds per-account token-per-minute (ITPM/OTPM) bucket settings
// for one tier. Per-minute values are converted to per-second at the call site.
// A dimension with a non-positive per-minute value is treated as unlimited.
type TokenConfig struct {
	InputPerMinute  float64
	InputBurst      int
	OutputPerMinute float64
	OutputBurst     int
}

// ConfigPair holds the rate-limiter configs for every account tier:
// inference (consumer), financial, and the elevated service tier, plus the
// per-tier token-per-minute (ITPM/OTPM) limits.
type ConfigPair struct {
	Inference      Config
	Financial      Config
	Service        Config
	ConsumerTokens TokenConfig
	ServiceTokens  TokenConfig
}

// ReadConfig reads all rate limiter configs from environment variables.
func ReadConfig() ConfigPair {
	return ConfigPair{
		// Consumer request limit is intentionally generous — the fleet
		// token-budget admission is the real capacity ceiling, so this is a
		// fairness/abuse guard, not a throughput brake.
		Inference: Config{
			RPS:   env.EnvFloat(env.EnvPrefix+"_RATE_LIMIT_RPS", 20.0),
			Burst: env.EnvInt(env.EnvPrefix+"_RATE_LIMIT_BURST", 120),
		},
		Financial: Config{
			RPS:   env.EnvFloat(env.EnvPrefix+"_FINANCIAL_RATE_LIMIT_RPS", 0.2),
			Burst: env.EnvInt(env.EnvPrefix+"_FINANCIAL_RATE_LIMIT_BURST", 3),
		},
		// Elevated tier for trusted service accounts (e.g. OpenRouter). Set RPS
		// to 0 to let service accounts bypass request rate limiting entirely.
		Service: Config{
			RPS:   env.EnvFloat(env.EnvPrefix+"_SERVICE_RATE_LIMIT_RPS", 200.0),
			Burst: env.EnvInt(env.EnvPrefix+"_SERVICE_RATE_LIMIT_BURST", 600),
		},
		ConsumerTokens: TokenConfig{
			InputPerMinute:  env.EnvFloat(env.EnvPrefix+"_RATE_LIMIT_ITPM", 5_000_000),
			InputBurst:      env.EnvInt(env.EnvPrefix+"_RATE_LIMIT_ITPM_BURST", 1_000_000),
			OutputPerMinute: env.EnvFloat(env.EnvPrefix+"_RATE_LIMIT_OTPM", 500_000),
			OutputBurst:     env.EnvInt(env.EnvPrefix+"_RATE_LIMIT_OTPM_BURST", 64_000),
		},
		ServiceTokens: TokenConfig{
			InputPerMinute:  env.EnvFloat(env.EnvPrefix+"_SERVICE_RATE_LIMIT_ITPM", 50_000_000),
			InputBurst:      env.EnvInt(env.EnvPrefix+"_SERVICE_RATE_LIMIT_ITPM_BURST", 5_000_000),
			OutputPerMinute: env.EnvFloat(env.EnvPrefix+"_SERVICE_RATE_LIMIT_OTPM", 5_000_000),
			OutputBurst:     env.EnvInt(env.EnvPrefix+"_SERVICE_RATE_LIMIT_OTPM_BURST", 512_000),
		},
	}
}

// Check validates the config. Currently a no-op.
func (c Config) Check() error { return nil }

// Check is a no-op for ConfigPair.
func (cp ConfigPair) Check() error { return nil }
