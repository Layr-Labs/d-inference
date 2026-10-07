package registry_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/env"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
)

func TestAutopilotRolloutDefaultsToShadowWithExplicitLiveSwitch(t *testing.T) {
	defaults := autopilot.DefaultConfig()
	if !defaults.Enabled || !defaults.ObserveOnly || defaults.LiveMachineIDs != "" {
		t.Fatalf("default must observe enrolled providers without activation: %+v", defaults)
	}
	prefix := env.EnvPrefix + "_AUTOPILOT_"
	t.Setenv(prefix+"ENABLED", "")
	t.Setenv(prefix+"LIVE_MACHINE_IDS", "")
	for _, tc := range []struct {
		value   string
		observe bool
	}{{"", true}, {"true", true}, {"false", false}, {"invalid", true}} {
		t.Run(tc.value, func(t *testing.T) {
			t.Setenv(prefix+"OBSERVE_ONLY", tc.value)
			cfg := production.ReadConfig().Autopilot
			if !cfg.Enabled || cfg.ObserveOnly != tc.observe {
				t.Fatalf("OBSERVE_ONLY=%q: enabled=%v observe=%v", tc.value, cfg.Enabled, cfg.ObserveOnly)
			}
		})
	}
}

func TestAutopilotLiveMachineAllowlistConfigIsStartupOnly(t *testing.T) {
	key := env.EnvPrefix + "_AUTOPILOT_LIVE_MACHINE_IDS"
	t.Setenv(key, " "+autopilotFixtureMachineID(0)+" ")
	cfg := production.ReadConfig().Autopilot
	if cfg.LiveMachineIDs != " "+autopilotFixtureMachineID(0)+" " {
		t.Fatal("configured allowlist was not read")
	}
	r := production.New(testLogger())
	if err := r.ConfigureAutopilot(cfg); err != nil {
		t.Fatal(err)
	}
	if err := r.ConfigureAutopilot(cfg); err != nil {
		t.Fatalf("identical startup config rejected: %v", err)
	}
	cfg.LiveMachineIDs = ""
	if err := r.ConfigureAutopilot(cfg); err == nil {
		t.Fatal("running controller accepted cohort removal")
	}
	t.Setenv(key, autopilotFixtureMachineID(0)+",*")
	if production.ReadConfig().Check() == nil {
		t.Fatal("invalid allowlist did not reject startup config")
	}
	if err := production.New(testLogger()).ConfigureAutopilot(production.ReadConfig().Autopilot); err == nil {
		t.Fatal("controller accepted a partially valid allowlist")
	}
}
