package app_test

import (
	"context"
	"io"
	"log/slog"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/config"
	"github.com/eigeninference/d-inference/coordinator/internal/startup"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestLegacyMDMStartupDeploymentPolicy(t *testing.T) {
	valid := api.AppAttestShadowConfig{ServingEnabled: true, Environment: "production", RolloutPercent: 100}
	for _, tc := range []struct {
		name, deployment, database string
		memory                     bool
		attest                     api.AppAttestShadowConfig
		wantErr, frozen            bool
	}{
		{name: "zero is production", wantErr: true},
		{name: "production disabled", deployment: "production", database: "configured", wantErr: true},
		{name: "production valid", deployment: "production", database: "configured", attest: valid, frozen: true},
		{name: "default valid", attest: valid, frozen: true},
		{name: "production partial", attest: api.AppAttestShadowConfig{ServingEnabled: true, Environment: "production", RolloutPercent: 50}, wantErr: true},
		{name: "apple development is not deployment development", attest: api.AppAttestShadowConfig{ServingEnabled: true, Environment: "development", RolloutPercent: 100}, wantErr: true},
		{name: "explicit dev database", deployment: "development", database: "configured"},
		{name: "dev apple development", deployment: "development", database: "configured", attest: api.AppAttestShadowConfig{Environment: "development"}},
		{name: "explicit memory", memory: true},
		{name: "database overrides memory", memory: true, database: "configured", wantErr: true},
		{name: "unknown fails even for memory", deployment: "staging", memory: true, attest: valid, wantErr: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cfg := config.AppConfig{DeploymentEnvironment: tc.deployment, StoreConfig: store.Config{DatabaseURL: tc.database, AllowMemoryStore: tc.memory}}
			logger := slog.New(slog.NewTextHandler(io.Discard, nil))
			srv := api.NewServer(registry.New(logger), memory.NewMemory(store.Config{}), api.ServerConfig{AppAttestShadow: tc.attest}, logger)
			t.Cleanup(srv.Close)
			err := startup.InitializeLegacyMDMPolicy(context.Background(), cfg, srv.Trust())
			if (err != nil) != tc.wantErr {
				t.Fatalf("startup error=%v, wantErr=%t", err, tc.wantErr)
			}
			if !tc.wantErr && srv.Trust().LegacyMDM.Initialized() != tc.frozen {
				t.Fatalf("initialized=%t, want frozen=%t", srv.Trust().LegacyMDM.Initialized(), tc.frozen)
			}
		})
	}
}

func TestDeploymentEnvironmentConfig(t *testing.T) {
	t.Setenv("DD_ENV", "development")
	t.Setenv("EIGENINFERENCE_APP_ATTEST_ENVIRONMENT", "development")
	t.Setenv("EIGENINFERENCE_DATABASE_URL", "configured")
	t.Setenv("EIGENINFERENCE_ALLOW_MEMORY_STORE", "true")
	for _, value := range []string{"", "production", "development", "dev", "unknown"} {
		t.Run(value, func(t *testing.T) {
			t.Setenv("EIGENINFERENCE_DEPLOYMENT_ENVIRONMENT", value)
			cfg := config.ReadAppConfig()
			if cfg.RequiresProductionAppAttest() != (value != "development") {
				t.Fatal("non-authoritative environment or memory flag changed production policy")
			}
			if value == "" && cfg.DeploymentEnvironment != "production" {
				t.Fatal("default deployment is not production")
			}
			if value == "dev" || value == "unknown" {
				if err := cfg.Check(); err == nil || !strings.Contains(err.Error(), "EIGENINFERENCE_DEPLOYMENT_ENVIRONMENT") {
					t.Fatalf("invalid deployment not rejected: %v", err)
				}
			} else if err := cfg.CheckDeploymentEnvironment(); err != nil {
				t.Fatal(err)
			}
		})
	}
}
