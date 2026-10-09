package api_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api"
)

func TestAutopilotRewardsConfigIsIndependentAndOffByDefault(t *testing.T) {
	if (api.ServerConfig{}).AutopilotRewardsEnabled {
		t.Fatal("zero config enables Autopilot payments")
	}
	t.Setenv("EIGENINFERENCE_BASE_REWARDS", "true")
	for _, tc := range []struct {
		value string
		want  bool
	}{{"", false}, {"false", false}, {"invalid", false}, {"true", true}} {
		t.Run(tc.value, func(t *testing.T) {
			t.Setenv("EIGENINFERENCE_AUTOPILOT_REWARDS", tc.value)
			cfg := api.ReadServerConfig()
			if cfg.AutopilotRewardsEnabled != tc.want || !cfg.BaseRewards.Enabled {
				t.Fatalf("payment toggles coupled: autopilot=%v base=%v", cfg.AutopilotRewardsEnabled, cfg.BaseRewards.Enabled)
			}
		})
	}
}
