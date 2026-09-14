package faultstate

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/env"
)

// Env tunables — read ONCE at Registry construction (coordinator restart
// applies changes). All values have safe defaults; setting the threshold to 0
// disables the cooldown entirely (kill switch).
const (
	envCapacityCooldownThreshold  = "EIGENINFERENCE_CAPACITY_COOLDOWN_THRESHOLD"
	envCapacityCooldownWindowSecs = "EIGENINFERENCE_CAPACITY_COOLDOWN_WINDOW_SECONDS"
	envCapacityCooldownTTLSecs    = "EIGENINFERENCE_CAPACITY_COOLDOWN_TTL_SECONDS"
	envCapacityCooldownMaxTTLSecs = "EIGENINFERENCE_CAPACITY_COOLDOWN_MAX_TTL_SECONDS"
)

const (
	defaultCapacityCooldownThreshold = 5
	defaultCapacityCooldownWindow    = 60 * time.Second
	defaultCapacityCooldownTTL       = 120 * time.Second
	defaultCapacityCooldownMaxTTL    = 10 * time.Minute
)

// capacityCooldownConfig carries the env-tunable cooldown parameters.
type capacityCooldownConfig struct {
	// Threshold is how many capacity rejects inside Window — with ZERO accepts
	// interleaved — trip the cooldown. <= 0 disables the breaker (kill switch).
	Threshold int
	// Window is the sliding window over which reject strikes count.
	Window time.Duration
	// BaseTTL is the first cooldown duration. Each re-trip without an
	// intervening accept doubles it (half-open re-arm), capped at MaxTTL.
	BaseTTL time.Duration
	// MaxTTL caps the exponential backoff.
	MaxTTL time.Duration
}

// loadCapacityCooldownConfig reads the EIGENINFERENCE_CAPACITY_COOLDOWN_* env
// tunables, falling back to the defaults and clamping nonsensical values
// (non-positive durations revert to defaults; MaxTTL is raised to BaseTTL).
func loadCapacityCooldownConfig() capacityCooldownConfig {
	cfg := capacityCooldownConfig{
		Threshold: env.EnvInt(envCapacityCooldownThreshold, defaultCapacityCooldownThreshold),
		Window:    time.Duration(env.EnvInt(envCapacityCooldownWindowSecs, int(defaultCapacityCooldownWindow/time.Second))) * time.Second,
		BaseTTL:   time.Duration(env.EnvInt(envCapacityCooldownTTLSecs, int(defaultCapacityCooldownTTL/time.Second))) * time.Second,
		MaxTTL:    time.Duration(env.EnvInt(envCapacityCooldownMaxTTLSecs, int(defaultCapacityCooldownMaxTTL/time.Second))) * time.Second,
	}
	if cfg.Window <= 0 {
		cfg.Window = defaultCapacityCooldownWindow
	}
	if cfg.BaseTTL <= 0 {
		cfg.BaseTTL = defaultCapacityCooldownTTL
	}
	if cfg.MaxTTL < cfg.BaseTTL {
		cfg.MaxTTL = cfg.BaseTTL
	}
	return cfg
}

// capacityCooldownBackoff returns the cooldown TTL for a pair that has already
// tripped `trips` times (0 = first trip): BaseTTL * 2^trips, capped at MaxTTL.
// The loop avoids overflowing the shift for large trip counts (mirrors
// providerBreakerBackoff).
func capacityCooldownBackoff(cfg capacityCooldownConfig, trips int) time.Duration {
	ttl := cfg.BaseTTL
	for i := 0; i < trips && ttl < cfg.MaxTTL; i++ {
		ttl *= 2
	}
	if ttl > cfg.MaxTTL {
		ttl = cfg.MaxTTL
	}
	return ttl
}
