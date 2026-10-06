package autopilot_test

import (
	"math"
	"testing"
	"time"

	production "github.com/eigeninference/d-inference/coordinator/registry/autopilot"
)

func TestAutopilotFreshnessIncludesConfiguredControlCadence(t *testing.T) {
	for _, tc := range []struct{ interval, age time.Duration }{
		{time.Second, 30 * time.Second},
		{10 * time.Second, 30 * time.Second},
		{30 * time.Second, 40 * time.Second},
		{time.Minute, 70 * time.Second},
	} {
		cfg := production.DefaultConfig()
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
		change func(*production.Config)
	}{
		{"zero snapshot freshness", func(c *production.Config) { c.MaxSnapshotAge = 0 }},
		{"long stale snapshot", func(c *production.Config) { c.MaxSnapshotAge = time.Hour }},
		{"expired acceptance", func(c *production.Config) { c.CommandAcceptTimeout = 0 }},
		{"watchdog before acceptance", func(c *production.Config) { c.CommandWatchdog = time.Second }},
		{"unbounded watchdog", func(c *production.Config) { c.CommandWatchdog = time.Hour }},
		{"zero backoff", func(c *production.Config) { c.FailureBackoff = 0 }},
		{"zero load prior", func(c *production.Config) { c.LoadTimePrior = 0 }},
		{"nan utilization", func(c *production.Config) { c.TargetUtilization = math.NaN() }},
		{"infinite benefit", func(c *production.Config) { c.MinBenefitSeconds = math.Inf(1) }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := production.DefaultConfig()
			c.Enabled = true
			tc.change(&c)
			if c.Check() == nil {
				t.Fatal("invalid active control policy accepted")
			}
		})
	}
}
