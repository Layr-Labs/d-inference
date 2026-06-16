package registry

import (
	"fmt"
	"os"
	"time"

	"github.com/eigeninference/d-inference/coordinator/env"
)

// Config holds registry-level configuration.
type Config struct {
	MinTrustLevel string
	WarmPool      WarmPoolConfig
	CacheAffinity CacheAffinityConfig
}

type CacheAffinityConfig struct {
	TTL     time.Duration
	BonusMs float64
}

type WarmPoolConfig struct {
	Enabled     bool
	ObserveOnly bool

	Interval time.Duration
	MinDwell time.Duration

	QueueAgeThreshold         time.Duration
	CapacityRejectThreshold   int
	WarmSaturationThreshold   float64
	TTFTMissThreshold         int
	SpeculativeStartThreshold int
	SpeculativeWinThreshold   int
	ColdDispatchThreshold     int
	LoadDurationThreshold     time.Duration

	MaxLoadsPerTick       int
	MaxGlobalPendingLoads int
}

// ReadConfig reads registry configuration from environment variables.
func ReadConfig() Config {
	return Config{
		MinTrustLevel: os.Getenv(env.EnvPrefix + "_MIN_TRUST"),
		WarmPool: WarmPoolConfig{
			Enabled:                   env.EnvBool(env.EnvPrefix+"_WARM_POOL_ENABLED", true),
			ObserveOnly:               env.EnvBool(env.EnvPrefix+"_WARM_POOL_OBSERVE_ONLY", false),
			Interval:                  envDuration(env.EnvPrefix+"_WARM_POOL_INTERVAL", 10*time.Second),
			MinDwell:                  envDuration(env.EnvPrefix+"_WARM_POOL_MIN_DWELL", 5*time.Minute),
			QueueAgeThreshold:         envDuration(env.EnvPrefix+"_WARM_POOL_QUEUE_AGE_THRESHOLD", 0),
			CapacityRejectThreshold:   env.EnvInt(env.EnvPrefix+"_WARM_POOL_CAPACITY_REJECT_THRESHOLD", 1),
			WarmSaturationThreshold:   env.EnvFloat(env.EnvPrefix+"_WARM_POOL_WARM_SATURATION_THRESHOLD", 0.8),
			TTFTMissThreshold:         env.EnvInt(env.EnvPrefix+"_WARM_POOL_TTFT_MISS_THRESHOLD", 1),
			SpeculativeStartThreshold: env.EnvInt(env.EnvPrefix+"_WARM_POOL_SPECULATIVE_START_THRESHOLD", 2),
			SpeculativeWinThreshold:   env.EnvInt(env.EnvPrefix+"_WARM_POOL_SPECULATIVE_WIN_THRESHOLD", 1),
			ColdDispatchThreshold:     env.EnvInt(env.EnvPrefix+"_WARM_POOL_COLD_DISPATCH_THRESHOLD", 1),
			LoadDurationThreshold:     envDuration(env.EnvPrefix+"_WARM_POOL_LOAD_DURATION_THRESHOLD", 20*time.Second),
			MaxLoadsPerTick:           env.EnvInt(env.EnvPrefix+"_WARM_POOL_MAX_LOADS_PER_TICK", 4),
			MaxGlobalPendingLoads:     env.EnvInt(env.EnvPrefix+"_WARM_POOL_MAX_GLOBAL_PENDING_LOADS", 16),
		},
		CacheAffinity: CacheAffinityConfig{
			TTL:     envDuration(env.EnvPrefix+"_CACHE_AFFINITY_TTL", cacheAffinityTTL),
			BonusMs: env.EnvFloat(env.EnvPrefix+"_CACHE_AFFINITY_BONUS_MS", defaultCacheAffinityBonusMs),
		},
	}
}

func envDuration(key string, fallback time.Duration) time.Duration {
	if v := os.Getenv(key); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			return d
		}
	}
	return fallback
}

// Check validates the configuration.
// An empty MinTrustLevel is valid and means "use the default".
func (c Config) Check() error {
	if c.MinTrustLevel == "" {
		if err := c.WarmPool.Check(); err != nil {
			return err
		}
		return c.CacheAffinity.Check()
	}
	// trustRank returns -1 for unrecognized trust levels.
	if trustRank(TrustLevel(c.MinTrustLevel)) < 0 {
		return fmt.Errorf("registry: invalid MinTrustLevel %q (valid: %q, %q, %q)",
			c.MinTrustLevel, TrustNone, TrustSelfSigned, TrustHardware)
	}
	if err := c.WarmPool.Check(); err != nil {
		return err
	}
	return c.CacheAffinity.Check()
}

func (c CacheAffinityConfig) Check() error {
	if c.TTL < 0 {
		return fmt.Errorf("registry: cache affinity ttl must be >= 0")
	}
	if c.BonusMs < 0 {
		return fmt.Errorf("registry: cache affinity bonus must be >= 0")
	}
	if c.BonusMs > 10_000 {
		return fmt.Errorf("registry: cache affinity bonus must be <= 10000ms")
	}
	return nil
}

func (c WarmPoolConfig) Check() error {
	if !c.Enabled && c.Interval == 0 {
		return nil
	}
	if c.Interval <= 0 {
		return fmt.Errorf("registry: warm pool interval must be > 0")
	}
	if c.MinDwell < 0 || c.QueueAgeThreshold < 0 || c.LoadDurationThreshold < 0 {
		return fmt.Errorf("registry: warm pool durations must be >= 0")
	}
	if c.WarmSaturationThreshold < 0 || c.WarmSaturationThreshold > 1 {
		return fmt.Errorf("registry: warm pool saturation threshold must be in [0,1]")
	}
	if c.CapacityRejectThreshold < 1 || c.TTFTMissThreshold < 1 || c.SpeculativeStartThreshold < 1 || c.SpeculativeWinThreshold < 1 || c.ColdDispatchThreshold < 1 {
		return fmt.Errorf("registry: warm pool pressure thresholds must be >= 1")
	}
	if c.MaxLoadsPerTick < 0 || c.MaxGlobalPendingLoads < 0 {
		return fmt.Errorf("registry: warm pool load limits must be >= 0")
	}
	return nil
}
