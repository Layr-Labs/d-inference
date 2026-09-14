package profiler

import (
	"math"
	"testing"
)

func TestProfilerEnvironmentKeepsExistingSwitchAndRateSemantics(t *testing.T) {
	for _, tc := range []struct {
		name, enabled, rate string
		wantEnabled         bool
		wantRate            float64
	}{
		{"defaults", "", "", true, 0.1},
		{"explicit off", "  oFf ", "0.4", false, 0.4},
		{"only off disables", "false", "invalid", true, 0.1},
		{"zero rate", "on", "0", true, 0},
		{"negative rate", "on", "-1", true, 0},
		{"rate above one", "on", "2", true, 1},
		{"positive infinity", "on", "+Inf", true, 1},
		{"negative infinity", "on", "-Inf", true, 0},
		{"existing NaN behavior", "on", "NaN", true, math.NaN()},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv(EnvEnabled, tc.enabled)
			t.Setenv(EnvSampleRate, tc.rate)
			config := ConfigFromEnv()
			if config.Enabled != tc.wantEnabled ||
				(!math.IsNaN(tc.wantRate) && config.SampleRate != tc.wantRate) ||
				(math.IsNaN(tc.wantRate) && !math.IsNaN(config.SampleRate)) {
				t.Fatalf("config = %+v; enabled=%v rate=%v expected", config, tc.wantEnabled, tc.wantRate)
			}
			p := New(config, Hooks{}, 1)
			defer p.Close()
			if p.Enabled() != tc.wantEnabled || p.HasSink() {
				t.Fatalf("no-store profiler: enabled=%v sink=%v", p.Enabled(), p.HasSink())
			}
			if math.IsNaN(tc.wantRate) && (p.sampled("request-id") || !p.sampled("")) {
				t.Fatal("NaN must preserve existing nonempty-ID rejection and empty-ID retention")
			}
		})
	}
}
