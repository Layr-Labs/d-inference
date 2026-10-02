package registry

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/env"
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
			cfg := autopilotConfigFromEnv()
			if !cfg.Enabled || cfg.ObserveOnly != tc.observe {
				t.Fatalf("OBSERVE_ONLY=%q: enabled=%v observe=%v", tc.value, cfg.Enabled, cfg.ObserveOnly)
			}
		})
	}
}
