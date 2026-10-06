package store_test

import (
	"context"
	"io"
	"log/slog"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/config"
	"github.com/eigeninference/d-inference/coordinator/internal/startup"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestLegacyMDMDevelopmentDoesNotFreezeProductionCohort(t *testing.T) {
	for name, st := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			logger := slog.New(slog.NewTextHandler(io.Discard, nil))
			dev := api.NewServer(registry.New(logger), st, api.ServerConfig{}, logger)
			t.Cleanup(dev.Close)
			cfg := config.AppConfig{DeploymentEnvironment: "development"}
			if err := startup.InitializeLegacyMDMPolicy(context.Background(), cfg, dev.Trust()); err != nil {
				t.Fatal(err)
			}
			if dev.Trust().LegacyMDM.Initialized() {
				t.Fatal("development initialized the production cohort")
			}
			eligible := legacyMDMFixture(t, st, "before-production", true)
			legacyMDMProof(t, st, eligible)
			prod := api.NewServer(registry.New(logger), st, api.ServerConfig{AppAttestShadow: api.AppAttestShadowConfig{
				ServingEnabled: true, Environment: "production", RolloutPercent: 100,
			}}, logger)
			t.Cleanup(prod.Close)
			cfg.DeploymentEnvironment = "production"
			if err := startup.InitializeLegacyMDMPolicy(context.Background(), cfg, prod.Trust()); err != nil {
				t.Fatal(err)
			}
			if !prod.Trust().LegacyMDM.IdentityAllowed(eligible.AccountID, eligible.SEPublicKey, eligible.SerialNumber) {
				t.Fatal("development prematurely froze the durable cohort")
			}
			late := legacyMDMFixture(t, st, "after-production", true)
			legacyMDMProof(t, st, late)
			if err := startup.InitializeLegacyMDMPolicy(context.Background(), cfg, prod.Trust()); err != nil {
				t.Fatal(err)
			}
			if prod.Trust().LegacyMDM.IdentityAllowed(late.AccountID, late.SEPublicKey, late.SerialNumber) {
				t.Fatal("production restart expanded the frozen cohort")
			}
		})
	}
}
