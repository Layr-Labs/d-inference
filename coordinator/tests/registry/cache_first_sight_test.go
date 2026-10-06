package registry_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheactivation"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachedemand"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheplan"
)

// firstSight plans a prompt a second after the previous one with first sight
// configured at minTokens, and reports whether the plan was prepared for its
// own follow-up. Prompts of one conversation share every block they both have.
func (f *demandStrideFixture) firstSight(promptTokens int, conversation uint32, minTokens int) (cacheplan.Plan, bool) {
	f.t.Helper()
	plan := demandTestPlan(f.generation, promptTokens, 0, conversation)
	f.now = f.now.Add(time.Second)
	prepared := plan.ObserveRouteDemand(f.generation, f.demand.tracker, f.key, f.now, minTokens)
	return plan, prepared
}

func assertNoFirstSight(t *testing.T, name string, plan cacheplan.Plan, prepared bool) {
	t.Helper()
	if prepared || plan.FirstSightTokens != 0 || plan.RepeatedPrefixTokens != 0 || plan.AffinityKey() != "" {
		t.Fatalf("%s: prepared=%v first sight=%d repeat=%d affinity key present=%v, want an untouched novel plan",
			name, prepared, plan.FirstSightTokens, plan.RepeatedPrefixTokens, plan.AffinityKey() != "")
	}
}

// Planned and FirstSight are recorded in one critical section, so a status
// read that races the planning path never sees more first-sight plans than
// planned ones.
func TestCacheFirstSightCountNeverExceedsPlanned(t *testing.T) {
	const plans = 20_000
	gate := cacheactivation.New(100, 0)
	done := make(chan struct{})
	go func() {
		defer close(done)
		for range plans {
			gate.RecordPlanned(true)
		}
	}()
	for running := true; running; {
		select {
		case <-done:
			running = false
		default:
		}
		if status := gate.Snapshot(); status.FirstSight > status.Planned {
			t.Fatalf("first sight=%d exceeds planned=%d", status.FirstSight, status.Planned)
		}
	}
	gate.RecordPlanned(false)
	if status := gate.Snapshot(); status.FirstSight != plans || status.Planned != plans+1 {
		t.Fatalf("status=%+v, want %d first-sight plans among %d planned", status, plans, plans+1)
	}
}

func TestCacheFirstSightIsOffUnlessConfigured(t *testing.T) {
	f := newDemandStrideFixture(t)
	assertNoFirstSight(t, "plain demand observation", f.plan(7_000, 0, 1), false)
	plan, prepared := f.firstSight(7_000, 2, 0)
	assertNoFirstSight(t, "zero minimum", plan, prepared)
}

// The provider keeps the checkpoint at the 1,024-token boundary at or below
// the first-sight count it is sent, so a novel prompt names its own deepest
// one. The repeat count stays 0: nothing was observed twice.
func TestCacheFirstSightKeepsTheDeepestStrideBoundary(t *testing.T) {
	for _, tc := range []struct{ promptTokens, firstSight, affinityBoundary int }{
		{1_025, 1_024, 1_024},
		{5_000, 4_096, 4_096},
		{7_000, 6_144, 4_096},
		{8_193, 8_192, 8_192},
		{70_000, 69_632, 65_536},
	} {
		f := newDemandStrideFixture(t)
		plan, prepared := f.firstSight(tc.promptTokens, 1, 1_024)
		if !prepared || plan.FirstSightTokens != tc.firstSight ||
			plan.RepeatedPrefixTokens != 0 || f.affinityTokens(plan) != tc.affinityBoundary {
			t.Fatalf("%d tokens: prepared=%v first sight=%d repeat=%d affinity boundary=%d, want %d kept, repeat 0 and affinity at %d",
				tc.promptTokens, prepared, plan.FirstSightTokens, plan.RepeatedPrefixTokens,
				f.affinityTokens(plan), tc.firstSight, tc.affinityBoundary)
		}
	}
}

// Affinity only helps when the first request and its follow-up name the same
// key: the follow-up's comes from what it matched in the demand history, the
// first request's from its own boundaries.
func TestCacheFirstSightFollowUpDerivesTheSameAffinityKey(t *testing.T) {
	for _, tc := range []struct{ promptTokens, growth, repeat, rung int }{
		{1_025, 10, 1_024, 1_024},
		{3_000, 1_500, 2_048, 2_048},
		{5_000, 400, 4_096, 4_096},
		{7_000, 400, 6_144, 4_096},
		// The follow-up crosses the 8,192 rung, which the first request never had.
		{8_000, 500, 7_168, 4_096},
		{70_000, 2_000, 69_632, 65_536},
		// The follow-up is more than 64 strides deeper, so its stride window
		// starts at 8,192 and it reaches the first request's boundaries only
		// through the power-of-two ladder.
		{7_000, 66_000, 4_096, 4_096},
	} {
		f := newDemandStrideFixture(t)
		first, prepared := f.firstSight(tc.promptTokens, 1, 1_024)
		if !prepared || f.affinityTokens(first) != tc.rung {
			t.Fatalf("%d tokens: prepared=%v affinity boundary=%d, want the rung at %d",
				tc.promptTokens, prepared, f.affinityTokens(first), tc.rung)
		}
		followUp, prepared := f.firstSight(tc.promptTokens+tc.growth, 1, 1_024)
		if prepared || followUp.FirstSightTokens != 0 || followUp.RepeatedPrefixTokens != tc.repeat {
			t.Fatalf("%d+%d tokens: prepared=%v first sight=%d repeat=%d, want an ordinary repeat of %d",
				tc.promptTokens, tc.growth, prepared, followUp.FirstSightTokens, followUp.RepeatedPrefixTokens, tc.repeat)
		}
		if followUp.AffinityKey() != first.AffinityKey() {
			t.Fatalf("%d+%d tokens: follow-up affinity boundary=%d, first request's=%d",
				tc.promptTokens, tc.growth, f.affinityTokens(followUp), f.affinityTokens(first))
		}
	}
}

func TestCacheFirstSightLeavesOtherPlansUntouched(t *testing.T) {
	f := newDemandStrideFixture(t)
	plan, prepared := f.firstSight(4_095, 1, 4_096)
	assertNoFirstSight(t, "one token below the minimum", plan, prepared)

	// 1,024 tokens end before the block at 1,024 completes: 768 is the last boundary.
	plan, prepared = f.firstSight(1_024, 2, 1_024)
	assertNoFirstSight(t, "no stride boundary", plan, prepared)

	if plan, prepared = f.firstSight(4_096, 3, 4_096); !prepared || plan.FirstSightTokens != 3_072 {
		t.Fatalf("prompt at the minimum: prepared=%v first sight=%d, want 3,072", prepared, plan.FirstSightTokens)
	}
	// Planning the same value again is a repeat, which owns the count it sends.
	f.now = f.now.Add(time.Second)
	if plan.ObserveRouteDemand(f.generation, f.demand.tracker, f.key, f.now, 4_096) ||
		plan.FirstSightTokens != 0 || plan.RepeatedPrefixTokens != 3_840 {
		t.Fatalf("repeated plan: first sight=%d repeat=%d, want 0 and its final boundary 3,840",
			plan.FirstSightTokens, plan.RepeatedPrefixTokens)
	}
}

// A plan holds a stride boundary without a rung only when its shallow keys are
// missing. FirstSight then falls back to its deepest stride boundary, while
// the tracker falls back to the deepest boundary the follow-up matched, of any
// kind. The keys agree here because a follow-up that extends the prompt
// matches that stride and nothing deeper.
func TestCacheFirstSightFallsBackToTheDeepestStride(t *testing.T) {
	stride := cachedemand.Boundary{Key: "stride-3072", Tokens: 3_072}
	own := []cachedemand.Boundary{{Key: "block-768", Tokens: 768}, {Key: "", Tokens: 2_048}, stride, {Key: "final-3328", Tokens: 3_328}}
	tokens, key := cachedemand.FirstSight(own)
	if tokens != 3_072 || key != stride.Key {
		t.Fatalf("first sight=%d key=%q, want the stride boundary", tokens, key)
	}
	d := newDemandFixture(8, time.Minute)
	now := time.Unix(1_700_000_000, 0)
	d.tracker.Observe(own, now)
	_, followUpKey := d.tracker.Observe([]cachedemand.Boundary{stride, {Key: "rung-4096", Tokens: 4_096}}, now.Add(time.Second))
	if followUpKey != key {
		t.Fatalf("follow-up key=%q, first request's=%q", followUpKey, key)
	}
	if tokens, key := cachedemand.FirstSight([]cachedemand.Boundary{{Key: "block-768", Tokens: 768}}); tokens != 0 || key != "" {
		t.Fatalf("prompt without a stride boundary: first sight=%d key=%q", tokens, key)
	}
	if tokens, key := cachedemand.FirstSight([]cachedemand.Boundary{{Key: "rung-2048", Tokens: 2_048}, stride}); tokens != 3_072 || key != "rung-2048" {
		t.Fatalf("first sight=%d key=%q, want the stride kept and the rung as key", tokens, key)
	}
}
