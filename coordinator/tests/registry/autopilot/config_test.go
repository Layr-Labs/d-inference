package autopilot_test

import (
	"math"
	"strings"
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

func TestAutopilotLiveMachineAllowlistIsCanonicalAndFailClosed(t *testing.T) {
	const machine = "a6b2a814-b6f5-4a90-a614-000000000001"
	for _, tc := range []struct {
		name    string
		raw     string
		want    int
		invalid bool
	}{
		{name: "empty"},
		{name: "blank", raw: " \t "},
		{name: "machine", raw: machine, want: 1},
		{name: "normalization and duplicates", raw: " " + strings.ToUpper(machine) + ", " + machine + " ", want: 1},
		{name: "two machines", raw: machine + ",a6b2a814-b6f5-4a90-a614-000000000002", want: 2},
		{name: "malformed", raw: "not-a-uuid", invalid: true},
		{name: "wildcard", raw: "*", invalid: true},
		{name: "account", raw: "did:privy:account-123", invalid: true},
		{name: "scoped account", raw: "account:" + machine, invalid: true},
		{name: "compact UUID", raw: strings.ReplaceAll(machine, "-", ""), invalid: true},
		{name: "URN", raw: "urn:uuid:" + machine, invalid: true},
		{name: "braces", raw: "{" + machine + "}", invalid: true},
		{name: "nil UUID", raw: "00000000-0000-0000-0000-000000000000", invalid: true},
		{name: "bad entry after valid", raw: machine + ",*", invalid: true},
		{name: "empty entry", raw: machine + ",", invalid: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cfg := production.DefaultConfig()
			cfg.LiveMachineIDs = tc.raw
			ids, err := cfg.ParseLiveMachineIDs()
			if (err != nil) != tc.invalid || len(ids) != tc.want {
				t.Fatalf("parsed=%v error=%v want count=%d invalid=%v", ids, err, tc.want, tc.invalid)
			}
			if tc.want > 0 {
				if _, ok := ids[machine]; !ok {
					t.Fatal("canonical machine ID not selected")
				}
			}
			for _, enabled := range []bool{true, false} {
				cfg.Enabled = enabled
				if (cfg.Check() != nil) != tc.invalid {
					t.Fatalf("invalid allowlist bypassed config validation when enabled=%v", enabled)
				}
			}
		})
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
