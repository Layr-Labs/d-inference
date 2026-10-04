package api

import (
	trustapi "github.com/eigeninference/d-inference/coordinator/api/provider/trust"
	attestservice "github.com/eigeninference/d-inference/coordinator/appattest/service"
	"github.com/eigeninference/d-inference/coordinator/env"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/responselimit"
	"github.com/eigeninference/d-inference/coordinator/internal/provider/journal"
	"github.com/eigeninference/d-inference/coordinator/mediafetch"
	"os"
	"strings"
	"time"
)

// ServerConfig holds coordinator HTTP server and URL configuration applied
// when NewServer constructs an instance.
type ServerConfig struct {
	// Non-positive values retain the safe defaults; limits cannot be disabled.
	NonStreamingResponseMaxBytes  int
	NonStreamingResponseMaxChunks int

	AppAttestShadow     AppAttestShadowConfig
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
	// DurableTrustReuse enables the fsync-backed local hard-untrust journal.
	// Production enables it when the coordinator uses its durable Postgres store.
	DurableTrustReuse     bool
	TrustReuseJournalPath string
	MDMScheduler          MDMSchedulerConfig
	// FirstContentDeadlineBase is the ordinary-model fixed term in the
	// request-absolute first-content budget for selected accounts. Model policy may override it;
	// zero keeps the ordinary coordinator default.
	FirstContentDeadlineBase time.Duration
	// FirstContentSLAAccounts selects exact authenticated account IDs or stored
	// emails. Empty disables the first-content SLA for all accounts.
	FirstContentSLAAccounts []string
	BaseRewards             BaseRewardsConfig
	// MediaFetch is the remote media resolution config (mediafetch package).
	// nil means "read it from the environment in NewServer", which keeps the
	// bare ServerConfig{} literals used by tests working unchanged. main.go
	// threads the AppConfig-validated value in.
	MediaFetch *mediafetch.Config
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
		NonStreamingResponseMaxBytes:  env.EnvInt(env.EnvPrefix+"_NONSTREAM_RESPONSE_MAX_BYTES", responselimit.DefaultMaxBytes),
		NonStreamingResponseMaxChunks: env.EnvInt(env.EnvPrefix+"_NONSTREAM_RESPONSE_MAX_CHUNKS", responselimit.DefaultMaxChunks),

		AppAttestShadow:         attestservice.ConfigFromEnvironment(),
		Port:                    env.EnvOr(env.EnvPrefix+"_PORT", "8080"),
		ConsoleURL:              os.Getenv(env.EnvPrefix + "_CONSOLE_URL"),
		CORSOrigin:              os.Getenv("CORS_ORIGIN"),
		BaseURL:                 os.Getenv(env.EnvPrefix + "_BASE_URL"),
		R2CDNURL:                os.Getenv(env.EnvPrefix + "_R2_CDN_URL"),
		MinProviderVersion:      os.Getenv(env.EnvPrefix + "_MIN_PROVIDER_VERSION"),
		AdminKey:                os.Getenv(env.EnvPrefix + "_ADMIN_KEY"),
		AdminEmails:             ParseCommaList(env.EnvOr(env.EnvPrefix+"_ADMIN_EMAILS", "")),
		ReleaseKey:              os.Getenv(env.EnvPrefix + "_RELEASE_KEY"),
		ServiceReservations:     env.EnvBool(env.EnvPrefix+"_SERVICE_RESERVATIONS_ENABLED", false),
		FirstContentSLAAccounts: ParseCommaList(os.Getenv(env.EnvPrefix + "_FIRST_CONTENT_SLA_ACCOUNTS")),
		TrustReuseJournalPath:   journal.ResolveTrustReuseRevocationJournalPath(),
		MDMScheduler:            trustapi.ReadMDMSchedulerConfig(),
		BaseRewards: BaseRewardsConfig{
			Enabled:        env.EnvBool(env.EnvPrefix+"_BASE_REWARDS", false),
			ReductionK:     env.EnvFloat(env.EnvPrefix+"_BASE_REWARDS_K", 0), // 0 = additive base income (full floor on top of earnings)
			FloorPoolB:     int64(env.EnvInt(env.EnvPrefix+"_BASE_REWARDS_POOL_MICRO", 9_000_000_000)),
			MinUptimeFrac:  env.EnvFloat(env.EnvPrefix+"_BASE_REWARDS_MIN_UPTIME", 0.90),
			AccountCapFrac: env.EnvFloat(env.EnvPrefix+"_BASE_REWARDS_ACCOUNT_CAP", 0), // 0 = per-machine (no per-account cap)
		},
	}
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

// These configuration names are part of the application setup API.
type MDMSchedulerConfig = trustapi.MDMSchedulerConfig
type AppAttestShadowConfig = attestservice.Config
