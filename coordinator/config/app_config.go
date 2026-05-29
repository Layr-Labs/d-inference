package config

import (
	"fmt"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/datadog"
	"github.com/eigeninference/d-inference/coordinator/env"
	"github.com/eigeninference/d-inference/coordinator/mdm"
	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// EnvPrefix is the namespace prefix for all coordinator environment variables.
const EnvPrefix = env.EnvPrefix

// AppConfig is the root configuration struct, composing per-package configs.
type AppConfig struct {
	StoreConfig    store.Config
	ServerConfig   api.ServerConfig
	BillingConfig  billing.Config
	AuthConfig     auth.Config
	RateLimitCfg   ratelimit.Config
	FinancialRL    ratelimit.Config
	ServiceRL      ratelimit.Config
	ConsumerTokens ratelimit.TokenConfig
	ServiceTokens  ratelimit.TokenConfig
	RegistryCfg    registry.Config
	MDMConfig      mdm.Config
	DatadogConfig  datadog.Config
	AdminKey       string
	AdminEmails    []string
	ReleaseKey     string
}

// Check runs validation on every per-package config.
func (c AppConfig) Check() error {
	if err := c.StoreConfig.Check(); err != nil {
		return fmt.Errorf("store: %w", err)
	}
	if err := c.BillingConfig.Check(); err != nil {
		return fmt.Errorf("billing: %w", err)
	}
	if err := c.AuthConfig.Check(); err != nil {
		return fmt.Errorf("auth: %w", err)
	}
	if err := c.RateLimitCfg.Check(); err != nil {
		return fmt.Errorf("rate_limit: %w", err)
	}
	if err := c.FinancialRL.Check(); err != nil {
		return fmt.Errorf("financial_rate_limit: %w", err)
	}
	if err := c.RegistryCfg.Check(); err != nil {
		return fmt.Errorf("registry: %w", err)
	}
	if err := c.MDMConfig.Check(); err != nil {
		return fmt.Errorf("mdm: %w", err)
	}
	if err := c.DatadogConfig.Check(); err != nil {
		return fmt.Errorf("datadog: %w", err)
	}
	return nil
}

// ReadAppConfig reads all per-package configs from the environment.
func ReadAppConfig() AppConfig {
	rlCfg := ratelimit.ReadConfig()
	return AppConfig{
		StoreConfig:    store.ReadConfig(),
		ServerConfig:   api.ReadServerConfig(),
		BillingConfig:  billing.ReadConfig(),
		AuthConfig:     auth.ReadConfig(),
		RateLimitCfg:   rlCfg.Inference,
		FinancialRL:    rlCfg.Financial,
		ServiceRL:      rlCfg.Service,
		ConsumerTokens: rlCfg.ConsumerTokens,
		ServiceTokens:  rlCfg.ServiceTokens,
		RegistryCfg:    registry.ReadConfig(),
		MDMConfig:      mdm.ReadConfig(),
		DatadogConfig:  datadog.ConfigFromEnv(),
		AdminKey:       EnvOr(EnvPrefix+"_ADMIN_KEY", ""),
		AdminEmails:    api.ParseCommaList(EnvOr(EnvPrefix+"_ADMIN_EMAILS", "")),
		ReleaseKey:     EnvOr(EnvPrefix+"_RELEASE_KEY", ""),
	}
}
