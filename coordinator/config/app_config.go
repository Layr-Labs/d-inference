package config

import (
	"fmt"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/datadog"
	"github.com/eigeninference/d-inference/coordinator/mdm"
	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// EnvPrefix is the namespace prefix for all environment variables
// consumed by the coordinator binary.
const EnvPrefix = "EIGENINFERENCE"

// AppConfig is the root configuration struct. It composes per-package configs
// so main.go wires the entire service from a single validated struct instead of
// reading dozens of environment variables inline.
type AppConfig struct {
	StoreConfig   store.Config
	ServerConfig  api.ServerConfig
	BillingConfig billing.Config
	AuthConfig    auth.Config
	RateLimitCfg  ratelimit.Config
	FinancialRL   ratelimit.Config
	RegistryCfg   registry.Config
	MDMConfig     mdm.Config
	DatadogConfig datadog.Config
	AdminKey      string
	AdminEmails   []string
	ReleaseKey    string
}

// Check runs validation on every per-package config and returns the first
// error. Call this before constructing services.
func (c AppConfig) Check() error {
	if err := c.StoreConfig.Check(); err != nil {
		return fmt.Errorf("store: %w", err)
	}
	if err := c.RateLimitCfg.Check(); err != nil {
		return fmt.Errorf("rate_limit: %w", err)
	}
	if err := c.FinancialRL.Check(); err != nil {
		return fmt.Errorf("financial_rate_limit: %w", err)
	}
	return nil
}

// ReadAppConfig reads all per-package configs from the environment and
// returns the composite AppConfig.
func ReadAppConfig() AppConfig {
	billingCfg := billing.ReadConfig()
	mdmCfg := mdm.ReadConfig()

	return AppConfig{
		StoreConfig:   store.ReadConfig(),
		ServerConfig:  api.ReadServerConfig(),
		BillingConfig: billingCfg,
		AuthConfig:    auth.ReadConfig(),
		RateLimitCfg:  ratelimit.ReadConsumerConfig(),
		FinancialRL:   ratelimit.ReadFinancialConfig(),
		RegistryCfg:   registry.ReadConfig(),
		MDMConfig:     mdmCfg,
		DatadogConfig: datadog.ConfigFromEnv(),
		AdminKey:      EnvOr(EnvPrefix+"_ADMIN_KEY", ""),
		AdminEmails:   api.ParseCommaList(EnvOr(EnvPrefix+"_ADMIN_EMAILS", "")),
		ReleaseKey:    EnvOr(EnvPrefix+"_RELEASE_KEY", ""),
	}
}
