package hedge_test

import (
	"testing"

	inferhedge "github.com/eigeninference/d-inference/coordinator/internal/inference/hedge"
)

// TestHedgeGovernorVerdictTable pins each launch rule, its precedence, and its
// boundary. Rules fire in order (queued → idle capacity → global budget →
// win rate), so each suppression names the FIRST failing condition.
func TestHedgeGovernorVerdictTable(t *testing.T) {
	// A baseline snapshot that passes every rule; each case perturbs it.
	allow := inferhedge.Inputs{
		IdleAlternativeExists: true,
		ModelQueueDepth:       0,
		ActiveHedges:          0,
		FleetIdleSlots:        8,
		ModelWinRate:          inferhedge.WinRateUnknown,
	}
	tests := []struct {
		name string
		in   inferhedge.Inputs
		want inferhedge.Verdict
	}{
		{"all rules pass", allow, inferhedge.Allow},
		{
			"zero-value inputs fail closed",
			inferhedge.Inputs{},
			inferhedge.SuppressNoIdleCapacity,
		},
		{
			"queued model never hedges",
			func() inferhedge.Inputs { in := allow; in.ModelQueueDepth = 1; return in }(),
			inferhedge.SuppressQueued,
		},
		{
			"queue outranks every other failure",
			inferhedge.Inputs{ModelQueueDepth: 3, ModelWinRate: 0.01},
			inferhedge.SuppressQueued,
		},
		{
			"no idle alternative, fleet headroom below threshold",
			inferhedge.Inputs{
				FleetIdleSlots: inferhedge.FleetIdleHeadroomSlots - 1,
				ModelWinRate:   inferhedge.WinRateUnknown,
			},
			inferhedge.SuppressNoIdleCapacity,
		},
		{
			"no idle alternative, fleet headroom at threshold",
			inferhedge.Inputs{
				FleetIdleSlots: inferhedge.FleetIdleHeadroomSlots,
				ModelWinRate:   inferhedge.WinRateUnknown,
			},
			inferhedge.Allow,
		},
		{
			"idle alternative substitutes for zero fleet headroom",
			inferhedge.Inputs{
				IdleAlternativeExists: true,
				FleetIdleSlots:        0,
				ModelWinRate:          inferhedge.WinRateUnknown,
			},
			inferhedge.Allow, // budget floor of 1 with idle capacity, activeHedges 0
		},
		{
			"budget boundary: last slot under budget allows",
			func() inferhedge.Inputs {
				in := allow // budget = 8/4 = 2
				in.ActiveHedges = 1
				return in
			}(),
			inferhedge.Allow,
		},
		{
			"budget boundary: at budget suppresses",
			func() inferhedge.Inputs {
				in := allow // budget = 8/4 = 2
				in.ActiveHedges = 2
				return in
			}(),
			inferhedge.SuppressGlobalBudget,
		},
		{
			"budget floor of one is consumable",
			inferhedge.Inputs{
				IdleAlternativeExists: true,
				FleetIdleSlots:        0,
				ActiveHedges:          1,
				ModelWinRate:          inferhedge.WinRateUnknown,
			},
			inferhedge.SuppressGlobalBudget,
		},
		{
			"win rate below floor suppresses",
			func() inferhedge.Inputs {
				in := allow
				in.ModelWinRate = inferhedge.WinRateFloor - 0.01
				in.ModelWinRateSamples = inferhedge.WinRateMinSamples
				return in
			}(),
			inferhedge.SuppressWinRate,
		},
		{
			"win rate at floor allows",
			func() inferhedge.Inputs {
				in := allow
				in.ModelWinRate = inferhedge.WinRateFloor
				return in
			}(),
			inferhedge.Allow,
		},
		{
			"unknown win rate passes through",
			func() inferhedge.Inputs {
				in := allow
				in.ModelWinRate = inferhedge.WinRateUnknown
				return in
			}(),
			inferhedge.Allow,
		},
		{
			"zero win rate suppresses",
			func() inferhedge.Inputs {
				in := allow
				in.ModelWinRate = 0
				in.ModelWinRateSamples = inferhedge.WinRateMinSamples
				return in
			}(),
			inferhedge.SuppressWinRate,
		},
		// P1-1: the floor's nine-losers-per-marginal-win economics needs
		// statistical footing — below hedgeWinRateMinSamples recorded
		// outcomes the floor is waived so an unlucky first race cannot lock
		// the model out of the sampling it needs to recover.
		{
			"below min samples the floor is waived",
			func() inferhedge.Inputs {
				in := allow
				in.ModelWinRate = 0
				in.ModelWinRateSamples = inferhedge.WinRateMinSamples - 1
				return in
			}(),
			inferhedge.Allow,
		},
		// P1-1: the periodic exploration hedge waives ONLY the win-rate
		// floor; every earlier rule still binds.
		{
			"exploration waives the win-rate floor",
			func() inferhedge.Inputs {
				in := allow
				in.ModelWinRate = 0
				in.ModelWinRateSamples = inferhedge.WinRateMinSamples
				in.ExploreNow = true
				return in
			}(),
			inferhedge.Allow,
		},
		{
			"exploration never outranks queued demand",
			func() inferhedge.Inputs {
				in := allow
				in.ModelQueueDepth = 1
				in.ModelWinRate = 0
				in.ModelWinRateSamples = inferhedge.WinRateMinSamples
				in.ExploreNow = true
				return in
			}(),
			inferhedge.SuppressQueued,
		},
		{
			"exploration never busts the global budget",
			func() inferhedge.Inputs {
				in := allow // budget = 8/4 = 2
				in.ActiveHedges = 2
				in.ModelWinRate = 0
				in.ModelWinRateSamples = inferhedge.WinRateMinSamples
				in.ExploreNow = true
				return in
			}(),
			inferhedge.SuppressGlobalBudget,
		},
	}
	for _, tt := range tests {
		if got := inferhedge.Evaluate(tt.in); got != tt.want {
			t.Errorf("%s: verdict = %v, want %v", tt.name, got, tt.want)
		}
	}
}

// TestHedgeGlobalBudget pins the budget arithmetic and its two boundary
// behaviors: zero with no idle capacity anywhere, floor of one whenever any
// idle capacity exists, and the divisor above the floor.
func TestHedgeGlobalBudget(t *testing.T) {
	tests := []struct {
		fleetIdleSlots int
		idleAlt        bool
		want           int
	}{
		{0, false, 0}, // saturated fleet runs no insurance
		{0, true, 1},  // model-scoped idle alternative keeps the floor
		{1, false, 1}, // 1/4 rounds to 0 → floor
		{3, false, 1},
		{4, false, 1},
		{8, false, 2},
		{100, false, 25},
	}
	for _, tt := range tests {
		if got := inferhedge.GlobalBudget(tt.fleetIdleSlots, tt.idleAlt); got != tt.want {
			t.Errorf("hedgeGlobalBudget(%d, %v) = %d, want %d",
				tt.fleetIdleSlots, tt.idleAlt, got, tt.want)
		}
	}
}

// TestHedgeVerdictStrings pins the bounded verdict vocabulary used as the
// routing.hedge_governor_suppressed metric tag and log field.
func TestHedgeVerdictStrings(t *testing.T) {
	tests := []struct {
		v    inferhedge.Verdict
		want string
	}{
		{inferhedge.Allow, "allow"},
		{inferhedge.SuppressQueued, "suppress_queued"},
		{inferhedge.SuppressNoIdleCapacity, "suppress_no_idle_capacity"},
		{inferhedge.SuppressGlobalBudget, "suppress_global_budget"},
		{inferhedge.SuppressWinRate, "suppress_win_rate"},
		{inferhedge.Verdict(99), "unknown"},
	}
	for _, tt := range tests {
		if got := tt.v.String(); got != tt.want {
			t.Errorf("hedgeVerdict(%d).String() = %q, want %q", tt.v, got, tt.want)
		}
	}
}
