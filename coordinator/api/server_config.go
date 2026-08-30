package api

import (
	"os"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/env"
	"github.com/eigeninference/d-inference/coordinator/mediafetch"
)

// ServerConfig holds coordinator HTTP server and URL configuration applied
// when NewServer constructs an instance.
type ServerConfig struct {
	Port                string
	ConsoleURL          string
	CORSOrigin          string
	BaseURL             string
	R2CDNURL            string
	MinProviderVersion  string
	AdminKey            string
	AdminEmails         []string
	ReleaseKey          string
	ServiceReservations bool
	// HardwareProofTTL controls reuse of a full MDM/MDA device proof. It is
	// always clamped to the reviewed [1h,24h] policy interval.
	HardwareProofTTL time.Duration
	// DurableTrustReuse enables the fsync-backed local hard-untrust journal.
	// Production enables it when the coordinator uses its durable Postgres store.
	DurableTrustReuse     bool
	TrustReuseJournalPath string
	MDMScheduler          MDMSchedulerConfig
	// FirstContentDeadlineBase is the ordinary-model fixed term in the
	// request-absolute first-content budget. Exact-model policy may tighten it;
	// zero keeps the ordinary coordinator default.
	FirstContentDeadlineBase time.Duration
	BaseRewards              BaseRewardsConfig
	// MediaFetch is the remote media resolution config (mediafetch package).
	// nil means "read it from the environment in NewServer", which keeps the
	// bare ServerConfig{} literals used by tests working unchanged. main.go
	// threads the AppConfig-validated value in.
	MediaFetch *mediafetch.Config
}

const (
	defaultMDMVerificationWorkers = 12
	defaultMDMVerificationQueue   = 4096
)

// MDMSchedulerConfig bounds all live SecurityInfo and MDA work. Retry windows
// are fixed policy; only fleet sizing, initial spread, and claim lifetime are
// deployment knobs.
type MDMSchedulerConfig struct {
	Workers          int
	QueueCapacity    int
	InitialSpreadMin time.Duration
	InitialSpreadMax time.Duration
	ClaimTTL         time.Duration
}

// BaseRewardsConfig holds the deployment knobs for the provider base-rewards
// engine. Policy constants (the floor table) live in payments/baserewards; only
// operational toggles are env-driven here. The
// feature is OFF unless Enabled is true, so the default config is a no-op.
type BaseRewardsConfig struct {
	Enabled        bool    // EIGENINFERENCE_BASE_REWARDS
	ReductionK     float64 // EIGENINFERENCE_BASE_REWARDS_K (0 = additive base income, default; 1 = legacy max backstop)
	FloorPoolB     int64   // EIGENINFERENCE_BASE_REWARDS_POOL_MICRO (µUSD/mo cap)
	MinUptimeFrac  float64 // EIGENINFERENCE_BASE_REWARDS_MIN_UPTIME
	AccountCapFrac float64 // EIGENINFERENCE_BASE_REWARDS_ACCOUNT_CAP (0 = per-machine, no cap)
}

// ReadServerConfig reads server configuration from environment variables.
func ReadServerConfig() ServerConfig {
	return ServerConfig{
		Port:                  env.EnvOr(env.EnvPrefix+"_PORT", "8080"),
		ConsoleURL:            os.Getenv(env.EnvPrefix + "_CONSOLE_URL"),
		CORSOrigin:            os.Getenv("CORS_ORIGIN"),
		BaseURL:               os.Getenv(env.EnvPrefix + "_BASE_URL"),
		R2CDNURL:              os.Getenv(env.EnvPrefix + "_R2_CDN_URL"),
		MinProviderVersion:    os.Getenv(env.EnvPrefix + "_MIN_PROVIDER_VERSION"),
		AdminKey:              os.Getenv(env.EnvPrefix + "_ADMIN_KEY"),
		AdminEmails:           ParseCommaList(env.EnvOr(env.EnvPrefix+"_ADMIN_EMAILS", "")),
		ReleaseKey:            os.Getenv(env.EnvPrefix + "_RELEASE_KEY"),
		ServiceReservations:   env.EnvBool(env.EnvPrefix+"_SERVICE_RESERVATIONS_ENABLED", false),
		HardwareProofTTL:      hardwareProofTTLFromEnv(),
		TrustReuseJournalPath: resolveTrustReuseRevocationJournalPath(),
		MDMScheduler:          readMDMSchedulerConfig(),
		BaseRewards: BaseRewardsConfig{
			Enabled:        env.EnvBool(env.EnvPrefix+"_BASE_REWARDS", false),
			ReductionK:     env.EnvFloat(env.EnvPrefix+"_BASE_REWARDS_K", 0), // 0 = additive base income (full floor on top of earnings)
			FloorPoolB:     int64(env.EnvInt(env.EnvPrefix+"_BASE_REWARDS_POOL_MICRO", 9_000_000_000)),
			MinUptimeFrac:  env.EnvFloat(env.EnvPrefix+"_BASE_REWARDS_MIN_UPTIME", 0.90),
			AccountCapFrac: env.EnvFloat(env.EnvPrefix+"_BASE_REWARDS_ACCOUNT_CAP", 0), // 0 = per-machine (no per-account cap)
		},
	}
}

func hardwareProofTTLFromEnv() time.Duration {
	raw := strings.TrimSpace(os.Getenv(env.EnvPrefix + "_HARDWARE_PROOF_TTL"))
	if raw == "" {
		return defaultHardwareProofTTL
	}
	parsed, err := time.ParseDuration(raw)
	if err != nil {
		return defaultHardwareProofTTL
	}
	return clampHardwareProofTTL(parsed)
}

func readMDMSchedulerConfig() MDMSchedulerConfig {
	workers := env.EnvInt(env.EnvPrefix+"_MDM_SCHEDULER_WORKERS", defaultMDMVerificationWorkers)
	if workers < 1 {
		workers = defaultMDMVerificationWorkers
	} else if workers > defaultMDMVerificationWorkers {
		workers = defaultMDMVerificationWorkers
	}
	queue := env.EnvInt(env.EnvPrefix+"_MDM_SCHEDULER_QUEUE_CAPACITY", defaultMDMVerificationQueue)
	if queue < 1 {
		queue = defaultMDMVerificationQueue
	} else if queue > defaultMDMVerificationQueue {
		queue = defaultMDMVerificationQueue
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
	return MDMSchedulerConfig{
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

// ParseCommaList splits a comma-separated environment variable and trims
// whitespace from each element. Returns nil when the input is empty.
func ParseCommaList(raw string) []string {
	if raw == "" {
		return nil
	}
	parts := strings.Split(raw, ",")
	result := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p != "" {
			result = append(result, p)
		}
	}
	return result
}
