package mdmscheduler

import (
	"os"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/env"
)

const (
	defaultWorkers = 12
	defaultQueue   = 4096
)

// Config bounds all live SecurityInfo and MDA work. Retry windows
// are fixed policy; only fleet sizing, initial spread, and claim lifetime are
// deployment knobs.
type Config struct {
	Workers          int
	QueueCapacity    int
	InitialSpreadMin time.Duration
	InitialSpreadMax time.Duration
	ClaimTTL         time.Duration
}

// ConfigFromEnv reads the existing deployment bounds and duration fallbacks.
func ConfigFromEnv() Config {
	workers := env.EnvInt(env.EnvPrefix+"_MDM_SCHEDULER_WORKERS", defaultWorkers)
	if workers < 1 {
		workers = defaultWorkers
	} else if workers > defaultWorkers {
		workers = defaultWorkers
	}
	queue := env.EnvInt(env.EnvPrefix+"_MDM_SCHEDULER_QUEUE_CAPACITY", defaultQueue)
	if queue < 1 {
		queue = defaultQueue
	} else if queue > defaultQueue {
		queue = defaultQueue
	}
	minSpread := durationEnvOr(env.EnvPrefix+"_MDM_INITIAL_SPREAD_MIN", 5*time.Second)
	maxSpread := durationEnvOr(env.EnvPrefix+"_MDM_INITIAL_SPREAD_MAX", 5*time.Minute)
	if minSpread < 0 || maxSpread < minSpread || maxSpread > 30*time.Minute {
		minSpread, maxSpread = 5*time.Second, 5*time.Minute
	}
	claimTTL := durationEnvOr(env.EnvPrefix+"_MDM_CLAIM_TTL", 3*time.Minute)
	if claimTTL < 2*time.Minute || claimTTL > 15*time.Minute {
		claimTTL = 3 * time.Minute
	}
	return Config{
		Workers: workers, QueueCapacity: queue,
		InitialSpreadMin: minSpread, InitialSpreadMax: maxSpread,
		ClaimTTL: claimTTL,
	}
}

func durationEnvOr(name string, fallback time.Duration) time.Duration {
	raw := strings.TrimSpace(os.Getenv(name))
	if raw == "" {
		return fallback
	}
	value, err := time.ParseDuration(raw)
	if err != nil {
		return fallback
	}
	return value
}

func normalizeConfig(cfg Config) Config {
	if cfg.Workers <= 0 {
		cfg.Workers = defaultWorkers
	} else if cfg.Workers > defaultWorkers {
		cfg.Workers = defaultWorkers
	}
	if cfg.QueueCapacity <= 0 {
		cfg.QueueCapacity = defaultQueue
	} else if cfg.QueueCapacity > defaultQueue {
		cfg.QueueCapacity = defaultQueue
	}
	if cfg.InitialSpreadMin < 0 {
		cfg.InitialSpreadMin = 0
	}
	if cfg.InitialSpreadMax < cfg.InitialSpreadMin {
		cfg.InitialSpreadMax = cfg.InitialSpreadMin
	}
	if cfg.InitialSpreadMax == 0 {
		cfg.InitialSpreadMin = 5 * time.Second
		cfg.InitialSpreadMax = 5 * time.Minute
	}
	if cfg.ClaimTTL <= 0 {
		cfg.ClaimTTL = 3 * time.Minute
	}
	return cfg
}
