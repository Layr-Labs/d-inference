package registry_test

import (
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/env"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
)

func TestAutopilotRolloutDefaultsToShadowWithExplicitLiveSwitch(t *testing.T) {
	defaults := autopilot.DefaultConfig()
	if !defaults.Enabled || !defaults.ObserveOnly {
		t.Fatalf("default must observe enrolled providers without activation: %+v", defaults)
	}
	prefix := env.EnvPrefix + "_AUTOPILOT_"
	t.Setenv(prefix+"ENABLED", "")
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

func TestAutopilotRemovedLiveMachineEnvironmentSelectorHasNoEffect(t *testing.T) {
	const machine = "a6b2a814-b6f5-4a90-a614-000000000001"
	key := env.EnvPrefix + "_AUTOPILOT_LIVE_MACHINE_IDS"
	t.Setenv(key, "")
	cfg := production.ReadConfig().Autopilot
	for _, raw := range []string{
		"", " \t ", machine, " " + strings.ToUpper(machine) + ", " + machine + " ",
		machine + ",a6b2a814-b6f5-4a90-a614-000000000002", "not-a-uuid", "*", "did:privy:account-123",
		"account:" + machine, strings.ReplaceAll(machine, "-", ""), "urn:uuid:" + machine, "{" + machine + "}",
		"00000000-0000-0000-0000-000000000000", machine + ",*", machine + ",",
	} {
		t.Run(raw, func(t *testing.T) {
			t.Setenv(key, raw)
			got := production.ReadConfig().Autopilot
			if got != cfg {
				t.Fatalf("removed environment selector changed config: got=%+v want=%+v", got, cfg)
			}
			if err := got.Check(); err != nil {
				t.Fatalf("removed environment selector still participates in validation: %v", err)
			}
		})
	}
}

func TestAutopilotGlobalRolloutConfigRemainsStartupOnly(t *testing.T) {
	cfg := autopilot.DefaultConfig()
	r := production.New(testLogger())
	if err := r.ConfigureAutopilot(cfg); err != nil {
		t.Fatal(err)
	}
	if err := r.ConfigureAutopilot(cfg); err != nil {
		t.Fatalf("identical startup config rejected: %v", err)
	}
	cfg.ObserveOnly = !cfg.ObserveOnly
	if err := r.ConfigureAutopilot(cfg); err == nil {
		t.Fatal("running controller accepted a global rollout change")
	}
}
