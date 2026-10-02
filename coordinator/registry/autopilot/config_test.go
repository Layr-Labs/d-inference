package autopilot

import (
	"math"
	"testing"
	"time"
)

func TestAutopilotFreshnessIncludesConfiguredControlCadence(t *testing.T) {
	for _, tc := range []struct{ interval, age time.Duration }{
		{time.Second, 30 * time.Second},
		{10 * time.Second, 30 * time.Second},
		{30 * time.Second, 40 * time.Second},
		{time.Minute, 70 * time.Second},
	} {
		cfg := DefaultConfig()
		cfg.Interval = tc.interval
		if err := cfg.Check(); err != nil {
			t.Fatal(err)
		}
		if got := cfg.ControlSnapshotMaxAge(); got != tc.age {
			t.Fatalf("interval=%v snapshot age=%v want=%v", tc.interval, got, tc.age)
		}
	}
}

func TestAutopilotControllerConfigRejectsUnsafeTimingAndNumericSettings(t *testing.T) {
	for _, tc := range []struct {
		name   string
		change func(*Config)
	}{
		{"zero snapshot freshness", func(c *Config) { c.MaxSnapshotAge = 0 }},
		{"long stale snapshot", func(c *Config) { c.MaxSnapshotAge = time.Hour }},
		{"expired acceptance", func(c *Config) { c.CommandAcceptTimeout = 0 }},
		{"watchdog before acceptance", func(c *Config) { c.CommandWatchdog = time.Second }},
		{"unbounded watchdog", func(c *Config) { c.CommandWatchdog = time.Hour }},
		{"zero backoff", func(c *Config) { c.FailureBackoff = 0 }},
		{"zero load prior", func(c *Config) { c.LoadTimePrior = 0 }},
		{"nan utilization", func(c *Config) { c.TargetUtilization = math.NaN() }},
		{"infinite benefit", func(c *Config) { c.MinBenefitSeconds = math.Inf(1) }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := DefaultConfig()
			c.Enabled = true
			tc.change(&c)
			if c.Check() == nil {
				t.Fatal("invalid active control policy accepted")
			}
		})
	}
}
