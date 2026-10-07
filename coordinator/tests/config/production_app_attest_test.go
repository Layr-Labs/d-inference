package config_test

import (
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/config"
)

func TestProductionAppAttestPreflight(t *testing.T) {
	t.Setenv(config.EnvPrefix+"_DATABASE_URL", "postgres://localhost/config-test")
	t.Setenv(config.EnvPrefix+"_DEPLOYMENT_ENVIRONMENT", "")
	valid := api.AppAttestShadowConfig{ServingEnabled: true, Environment: "production", RolloutPercent: 100}
	for _, tc := range []struct {
		name       string
		deployment string
		memory     bool
		noDatabase bool
		attest     api.AppAttestShadowConfig
		wantErr    string
	}{
		{name: "default production disabled", wantErr: "app_attest: "},
		{name: "production disabled", deployment: "production", attest: api.AppAttestShadowConfig{Environment: "production", RolloutPercent: 100}, wantErr: "app_attest: "},
		{name: "shadow is not serving", attest: api.AppAttestShadowConfig{Enabled: true, Environment: "production", RolloutPercent: 100}, wantErr: "app_attest: "},
		{name: "wrong proof environment", attest: api.AppAttestShadowConfig{ServingEnabled: true, Environment: "development", RolloutPercent: 100}, wantErr: "app_attest: "},
		{name: "missing proof environment", attest: api.AppAttestShadowConfig{ServingEnabled: true, RolloutPercent: 100}, wantErr: "app_attest: "},
		{name: "zero rollout", attest: api.AppAttestShadowConfig{ServingEnabled: true, Environment: "production"}, wantErr: "app_attest: "},
		{name: "partial rollout", attest: api.AppAttestShadowConfig{ServingEnabled: true, Environment: "production", RolloutPercent: 99}, wantErr: "app_attest: "},
		{name: "excess rollout", attest: api.AppAttestShadowConfig{ServingEnabled: true, Environment: "production", RolloutPercent: 101}, wantErr: "app_attest: "},
		{name: "production valid", deployment: "production", attest: valid},
		{name: "zero deployment valid", attest: valid},
		{name: "explicit development", deployment: "development"},
		{name: "development partial rollout", deployment: "development", attest: api.AppAttestShadowConfig{ServingEnabled: true, Environment: "development", RolloutPercent: 50}},
		{name: "actual memory fallback", memory: true, noDatabase: true},
		{name: "production actual memory fallback", deployment: "production", memory: true, noDatabase: true},
		{name: "database overrides memory opt-in", memory: true, wantErr: "app_attest: "},
		{name: "missing memory opt-in", noDatabase: true, wantErr: "store: "},
		{name: "unknown deployment with memory", deployment: "staging", memory: true, noDatabase: true, wantErr: "EIGENINFERENCE_DEPLOYMENT_ENVIRONMENT"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cfg := config.ReadAppConfig()
			if cfg.DeploymentEnvironment != "production" {
				t.Fatal("unset deployment environment must default to production")
			}
			cfg.DeploymentEnvironment = tc.deployment
			cfg.StoreConfig.AllowMemoryStore = tc.memory
			if tc.noDatabase {
				cfg.StoreConfig.DatabaseURL = ""
			}
			cfg.ServerConfig.AppAttestShadow = tc.attest
			err := cfg.Check()
			if tc.wantErr == "" {
				if err != nil {
					t.Fatalf("Check() = %v, want nil", err)
				}
			} else if err == nil || !strings.HasPrefix(err.Error(), tc.wantErr) {
				t.Fatalf("Check() = %v, want error starting with %q", err, tc.wantErr)
			}
		})
	}
}
