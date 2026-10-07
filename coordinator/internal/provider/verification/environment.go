package verification

import (
	"os"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/env"
)

const (
	MaxWorkers       = 12
	MaxQueueCapacity = 4096
)

// MDMSchedulerConfig bounds all live SecurityInfo and MDA work. Retry windows
// are fixed policy; only fleet sizing, initial spread, and claim lifetime are
// deployment knobs.
type Config struct {
	Workers          int
	QueueCapacity    int
	InitialSpreadMin time.Duration
	InitialSpreadMax time.Duration
	ClaimTTL         time.Duration
}

func ReadConfig() Config {
	workers := env.EnvInt(env.EnvPrefix+"_MDM_SCHEDULER_WORKERS", MaxWorkers)
	if workers < 1 {
		workers = MaxWorkers
	} else if workers > MaxWorkers {
		workers = MaxWorkers
	}
	queue := env.EnvInt(env.EnvPrefix+"_MDM_SCHEDULER_QUEUE_CAPACITY", MaxQueueCapacity)
	if queue < 1 {
		queue = MaxQueueCapacity
	} else if queue > MaxQueueCapacity {
		queue = MaxQueueCapacity
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
