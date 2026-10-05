package modelpolicy_test

import (
	"strconv"
	"testing"
	"time"

	production "github.com/eigeninference/d-inference/coordinator/modelpolicy"
)

func useDefaultDeadlinePolicy(t *testing.T) {
	t.Helper()
	// A valid base override rebuilds the built-in table before applying its pair.
	// Reapply the built-in Qwen value to reset through the same public startup API.
	raw := production.Qwen3VL30BA3BInstructModelID + "=" + strconv.FormatInt(int64(production.Qwen3VL30BA3BInstructUpstreamFirstContentBase/time.Millisecond), 10)
	reset := func() {
		if replaced, removed := production.SetFirstContentBasesFromEnv(raw); replaced != 1 || removed != 0 {
			t.Fatalf("reset deadline policy = (%d,%d), want (1,0)", replaced, removed)
		}
	}
	reset()
	t.Cleanup(reset)
}

func TestFirstContentDeadlinesByExactModel(t *testing.T) {
	tests := []struct {
		name            string
		model           string
		promptTokens    int
		wantUpstream    time.Duration
		wantCoordinator time.Duration
	}{
		{
			name:            "ordinary model",
			model:           "ordinary-model",
			promptTokens:    321,
			wantUpstream:    10*time.Second + 321*time.Millisecond,
			wantCoordinator: 9*time.Second + 321*time.Millisecond,
		},
		{
			name:            "exact Qwen3-VL instruct",
			model:           production.Qwen3VL30BA3BInstructModelID,
			promptTokens:    321,
			wantUpstream:    5*time.Second + 321*time.Millisecond,
			wantCoordinator: 4*time.Second + 321*time.Millisecond,
		},
		{
			name:            "Qwen3-VL lookalike",
			model:           production.Qwen3VL30BA3BInstructModelID + "-preview",
			promptTokens:    321,
			wantUpstream:    10*time.Second + 321*time.Millisecond,
			wantCoordinator: 9*time.Second + 321*time.Millisecond,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := production.UpstreamFirstContentDeadline(
				tt.model, tt.promptTokens, production.StandardUpstreamFirstContentBase,
			); got != tt.wantUpstream {
				t.Fatalf("upstream deadline = %v, want %v", got, tt.wantUpstream)
			}
			if got := production.CoordinatorFirstContentDeadline(
				tt.model, tt.promptTokens,
				production.StandardUpstreamFirstContentBase-production.FirstContentResponseHeadroom,
			); got != tt.wantCoordinator {
				t.Fatalf("coordinator deadline = %v, want %v", got, tt.wantCoordinator)
			}
		})
	}
}

func TestFirstContentDeadlineClampsNegativePromptTokens(t *testing.T) {
	if got := production.UpstreamFirstContentDeadline(
		production.Qwen3VL30BA3BInstructModelID, -1, production.StandardUpstreamFirstContentBase,
	); got != production.Qwen3VL30BA3BInstructUpstreamFirstContentBase {
		t.Fatalf("upstream deadline = %v, want base only", got)
	}
	if got := production.CoordinatorFirstContentDeadline(
		production.Qwen3VL30BA3BInstructModelID, -1, 9*time.Second,
	); got != production.Qwen3VL30BA3BInstructCoordinatorFirstContentBase {
		t.Fatalf("coordinator deadline = %v, want base only", got)
	}
}

func TestOrdinaryDeadlineBasesRemainConfigurable(t *testing.T) {
	const promptTokens = 25
	if got, want := production.UpstreamFirstContentDeadline(
		"ordinary-model", promptTokens, 12*time.Second,
	), 12*time.Second+25*time.Millisecond; got != want {
		t.Fatalf("upstream deadline = %v, want %v", got, want)
	}
	if got, want := production.CoordinatorFirstContentDeadline(
		"ordinary-model", promptTokens, 8*time.Second,
	), 8*time.Second+25*time.Millisecond; got != want {
		t.Fatalf("coordinator deadline = %v, want %v", got, want)
	}
}

func TestModelOverridesNeverLoosenTighterGlobalDeadline(t *testing.T) {
	const promptTokens = 25
	if got, want := production.UpstreamFirstContentDeadline(
		production.Qwen3VL30BA3BInstructModelID, promptTokens, 3*time.Second,
	), 3*time.Second+25*time.Millisecond; got != want {
		t.Fatalf("upstream deadline = %v, want tighter global %v", got, want)
	}
	if got, want := production.CoordinatorFirstContentDeadline(
		production.Qwen3VL30BA3BInstructModelID, promptTokens, 3*time.Second,
	), 3*time.Second+25*time.Millisecond; got != want {
		t.Fatalf("coordinator deadline = %v, want tighter global %v", got, want)
	}
}

// TestSetFirstContentBasesFromEnv pins the operator escape hatch the
// 2026-09-01 incident lacked: the hardcoded Qwen3-VL 5s/4s pair killed ~47%
// of vision traffic (success p90 3.4s, right at the 4s line) with no way to
// loosen it short of a rebuild. EIGENINFERENCE_MODEL_FIRST_CONTENT_BASES
// replaces an exact-model upstream base (coordinator keeps the upstream−1s
// headroom), 0/"off" removes the entry, unset preserves today's table
// exactly, and invalid pairs are skipped.
func TestSetFirstContentBasesFromEnv(t *testing.T) {
	useDefaultDeadlinePolicy(t)

	prodCoordinatorBase := production.StandardUpstreamFirstContentBase - production.FirstContentResponseHeadroom // 9s

	// Blank (env unset) is a no-op: today's constants apply exactly.
	if r, rm := production.SetFirstContentBasesFromEnv(""); r != 0 || rm != 0 {
		t.Fatalf("blank = (%d,%d), want (0,0)", r, rm)
	}
	if got := production.UpstreamFirstContentDeadline(production.Qwen3VL30BA3BInstructModelID, 0, production.StandardUpstreamFirstContentBase); got != 5*time.Second {
		t.Fatalf("default upstream = %v, want the built-in 5s", got)
	}
	if got := production.CoordinatorFirstContentDeadline(production.Qwen3VL30BA3BInstructModelID, 0, prodCoordinatorBase); got != 4*time.Second {
		t.Fatalf("default coordinator = %v, want the built-in 4s", got)
	}

	// Loosen Qwen3-VL to an 8000ms upstream base → 7s coordinator base
	// (upstream − 1s headroom preserved).
	if r, rm := production.SetFirstContentBasesFromEnv(production.Qwen3VL30BA3BInstructModelID + "=8000"); r != 1 || rm != 0 {
		t.Fatalf("loosen = (%d,%d), want (1,0)", r, rm)
	}
	if got := production.UpstreamFirstContentDeadline(production.Qwen3VL30BA3BInstructModelID, 0, production.StandardUpstreamFirstContentBase); got != 8*time.Second {
		t.Fatalf("overridden upstream = %v, want 8s", got)
	}
	if got := production.CoordinatorFirstContentDeadline(production.Qwen3VL30BA3BInstructModelID, 0, prodCoordinatorBase); got != 7*time.Second {
		t.Fatalf("overridden coordinator = %v, want 7s (8s − 1s headroom)", got)
	}
	// Exact-model policy remains a tightening ceiling: a tighter emergency
	// GLOBAL base still wins over the loosened exact entry.
	if got := production.UpstreamFirstContentDeadline(production.Qwen3VL30BA3BInstructModelID, 0, 3*time.Second); got != 3*time.Second {
		t.Fatalf("tighter global vs override = %v, want 3s", got)
	}

	// "off" removes the exact entry: the model falls back to the global base.
	if r, rm := production.SetFirstContentBasesFromEnv(production.Qwen3VL30BA3BInstructModelID + "=off"); r != 0 || rm != 1 {
		t.Fatalf("off = (%d,%d), want (0,1)", r, rm)
	}
	if got := production.UpstreamFirstContentDeadline(production.Qwen3VL30BA3BInstructModelID, 0, production.StandardUpstreamFirstContentBase); got != production.StandardUpstreamFirstContentBase {
		t.Fatalf("upstream after off = %v, want the global %v", got, production.StandardUpstreamFirstContentBase)
	}
	if got := production.CoordinatorFirstContentDeadline(production.Qwen3VL30BA3BInstructModelID, 0, prodCoordinatorBase); got != prodCoordinatorBase {
		t.Fatalf("coordinator after off = %v, want the global %v", got, prodCoordinatorBase)
	}

	// All-invalid input applies nothing and keeps the CURRENT table (the
	// removed entry must not be resurrected): malformed pair, non-numeric,
	// empty model, an upstream base at/below the 1s headroom, and a negative.
	if r, rm := production.SetFirstContentBasesFromEnv("garbage,foo=abc,=5000," +
		production.Qwen3VL30BA3BInstructModelID + "=500,neg=-7000"); r != 0 || rm != 0 {
		t.Fatalf("all-invalid = (%d,%d), want (0,0)", r, rm)
	}
	if got := production.UpstreamFirstContentDeadline(production.Qwen3VL30BA3BInstructModelID, 0, production.StandardUpstreamFirstContentBase); got != production.StandardUpstreamFirstContentBase {
		t.Fatalf("upstream after invalid = %v, want the global (invalid input must not resurrect the entry)", got)
	}

	// "0" removes like "off"; the valid pair in a mixed string still applies
	// while its invalid siblings are ignored.
	if r, rm := production.SetFirstContentBasesFromEnv(production.Qwen3VL30BA3BInstructModelID + "=0"); r != 0 || rm != 1 {
		t.Fatalf("zero = (%d,%d), want (0,1)", r, rm)
	}
	if r, rm := production.SetFirstContentBasesFromEnv("garbage," + production.Qwen3VL30BA3BInstructModelID + "=6000,foo=abc"); r != 1 || rm != 0 {
		t.Fatalf("mixed = (%d,%d), want (1,0)", r, rm)
	}
	if got := production.UpstreamFirstContentDeadline(production.Qwen3VL30BA3BInstructModelID, 0, production.StandardUpstreamFirstContentBase); got != 6*time.Second {
		t.Fatalf("mixed-apply upstream = %v, want 6s", got)
	}

	// Removing a model that has no exact entry is a recognized no-op.
	if r, rm := production.SetFirstContentBasesFromEnv("never-had-an-entry=off"); r != 0 || rm != 0 {
		t.Fatalf("remove-absent = (%d,%d), want (0,0)", r, rm)
	}

	// Overflow / absurd values are rejected: above the 10-minute sanity
	// ceiling (also far below any time.Duration overflow), a value that
	// cannot even parse as int64, and math.MaxInt64 ms (which WOULD overflow
	// time.Duration if multiplied through). None may change the table.
	for _, raw := range []string{
		production.Qwen3VL30BA3BInstructModelID + "=700000",               // 11.7 min > 10 min ceiling
		production.Qwen3VL30BA3BInstructModelID + "=99999999999999999999", // > int64
		production.Qwen3VL30BA3BInstructModelID + "=9223372036854775807",  // MaxInt64 ms
	} {
		if r, rm := production.SetFirstContentBasesFromEnv(raw); r != 0 || rm != 0 {
			t.Fatalf("overflow %q = (%d,%d), want (0,0)", raw, r, rm)
		}
	}
	if got := production.UpstreamFirstContentDeadline(production.Qwen3VL30BA3BInstructModelID, 0, production.StandardUpstreamFirstContentBase); got != 6*time.Second {
		t.Fatalf("upstream after overflow attempts = %v, want the prior 6s override untouched", got)
	}
}
