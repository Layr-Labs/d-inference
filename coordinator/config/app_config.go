// Package config aggregates per-package configuration structs into a single
// AppConfig and reads them from the environment.
//
// Each package in the coordinator owns its own Config struct and ReadConfig()
// function. AppConfig composes them so main.go receives a single validated
// configuration object instead of reading dozens of environment variables
// inline. Environment-variable helpers live in the env package.
//
// Pattern adapted from: https://github.com/Layr-Labs/eigenda-proxy
package config

import (
	"fmt"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/datadog"
	"github.com/eigeninference/d-inference/coordinator/env"
	"github.com/eigeninference/d-inference/coordinator/mdm"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// EnvPrefix is the namespace prefix for all coordinator environment variables.
const EnvPrefix = env.EnvPrefix

// AppConfig is the root configuration struct, composing per-package configs.
type AppConfig struct {
	StoreConfig     store.Config
	ServerConfig    api.ServerConfig
	BillingConfig   billing.Config
	AuthConfig      auth.Config
	RateLimitCfg    ratelimit.Config
	FinancialRL     ratelimit.Config
	ServiceRL       ratelimit.Config
	ConsumerTokens  ratelimit.TokenConfig
	ServiceTokens   ratelimit.TokenConfig
	OutputAdmission ratelimit.OutputAdmissionEstimatorConfig
	RegistryCfg     registry.Config
	MDMConfig       mdm.Config
	DatadogConfig   datadog.Config
	PromptSidecar   promptcontract.SupervisorConfig
	AdminKey        string
	AdminEmails     []string
	ReleaseKey      string
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
	if err := c.PromptSidecar.Check(); err != nil {
		return fmt.Errorf("prompt_sidecar: %w", err)
	}
	return nil
}

// ReadAppConfig reads all per-package configs from the environment.
func ReadAppConfig() AppConfig {
	rlCfg := ratelimit.ReadConfig()
	return AppConfig{
		StoreConfig:     store.ReadConfig(),
		ServerConfig:    api.ReadServerConfig(),
		BillingConfig:   billing.ReadConfig(),
		AuthConfig:      auth.ReadConfig(),
		RateLimitCfg:    rlCfg.Inference,
		FinancialRL:     rlCfg.Financial,
		ServiceRL:       rlCfg.Service,
		ConsumerTokens:  rlCfg.ConsumerTokens,
		ServiceTokens:   rlCfg.ServiceTokens,
		OutputAdmission: rlCfg.OutputAdmission,
		RegistryCfg:     registry.ReadConfig(),
		MDMConfig:       mdm.ReadConfig(),
		DatadogConfig:   datadog.ConfigFromEnv(),
		PromptSidecar:   promptcontract.ReadSupervisorConfig(),
		AdminKey:        env.EnvOr(EnvPrefix+"_ADMIN_KEY", ""),
		AdminEmails:     api.ParseCommaList(env.EnvOr(EnvPrefix+"_ADMIN_EMAILS", "")),
		ReleaseKey:      env.EnvOr(EnvPrefix+"_RELEASE_KEY", ""),
	}
}
