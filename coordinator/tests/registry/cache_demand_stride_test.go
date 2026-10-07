package registry_test

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachedemand"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// The provider keeps the checkpoint on the 1,024-token stride at or below the
// reported repeat. The geometric rule reported 4,096 for a 7,000-token shared
// prefix and 8,192 for a 12,000-token one.
func TestCacheDemandReportsDeepestSharedStrideBoundary(t *testing.T) {
	for _, tc := range []struct {
		name                  string
		first, second, shared int
		want                  int
	}{
		{"shared_7000", 9_000, 10_000, 7_000, 6_144},
		{"shared_12000", 20_000, 16_000, 12_000, 11_264},
		{"shared_exactly_on_stride", 9_000, 9_000, 4_096, 4_096},
		{"shared_one_token_short_of_stride", 9_000, 9_000, 4_095, 3_072},
		{"shared_900_is_below_the_floor", 3_000, 3_000, 900, 0},
		{"shared_1023_is_below_the_floor", 3_000, 5_000, 1_023, 0},
		{"shared_1024", 3_000, 5_000, 1_024, 1_024},
		{"nothing_shared", 9_000, 9_000, 0, 0},
		// Longer than the 64-stride window: the ladder below it still reads
		// and records the shallow rungs. Each of the first three reported 0.
		{"long_pair_shares_8192", 100_000, 100_000, 8_192, 8_192},
		{"short_then_long_shares_8192", 10_000, 100_000, 8_192, 8_192},
		{"long_then_short_shares_8192", 100_000, 10_000, 8_192, 8_192},
		{"long_pair_shares_inside_the_window", 100_000, 100_000, 50_000, 49_152},
		// Below the window only rungs are observed, so 20,000 shared tokens
		// report the rung at 16,384 rather than the stride at 19,456.
		{"long_pair_shares_below_the_window", 100_000, 100_000, 20_000, 16_384},
		{"long_pair_shares_900", 100_000, 100_000, 900, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newDemandStrideFixture(t)
			if repeat, _ := f.observe(tc.first, tc.shared, 1); repeat != 0 {
				t.Fatalf("first plan reported a repeat of %d", repeat)
			}
			if repeat, _ := f.observe(tc.second, tc.shared, 2); repeat != tc.want {
				t.Fatalf("plans sharing %d tokens reported %d, want %d", tc.shared, repeat, tc.want)
			}
		})
	}
}

// A plan's final boundary is observed wherever it falls. Below 1,024 tokens
// it is the only observation, so a short prompt repeats only against an
// earlier plan that ended on the same boundary.
func TestCacheDemandFinalBoundaryRule(t *testing.T) {
	f := newDemandStrideFixture(t)
	if repeat, affinity := f.observe(900, 900, 1); repeat != 0 || affinity {
		t.Fatalf("first short plan: repeat=%d affinity=%v", repeat, affinity)
	}
	if got := f.entries(); got != 1 {
		t.Fatalf("a 900-token plan recorded %d entries, want its final boundary only", got)
	}
	// The same 900 tokens again: both plans end at 768.
	if repeat, affinity := f.observe(900, 900, 1); repeat != 768 || !affinity {
		t.Fatalf("identical short plan: repeat=%d affinity=%v, want 768", repeat, affinity)
	}
	// A longer prompt that starts with those 900 tokens observes 1,024 and up
	// and its own end; it does not read 768, where no checkpoint can exist.
	if repeat, affinity := f.observe(3_000, 900, 2); repeat != 0 || affinity {
		t.Fatalf("longer plan over a short one: repeat=%d affinity=%v, want none", repeat, affinity)
	}
	// An unaligned final boundary above the floor repeats for an identical plan.
	if repeat, _ := f.observe(7_000, 7_000, 3); repeat != 0 {
		t.Fatalf("first 7,000-token plan reported %d", repeat)
	}
	if repeat, _ := f.observe(7_000, 7_000, 3); repeat != 6_912 {
		t.Fatalf("identical 7,000-token plan reported %d, want its final boundary 6,912", repeat)
	}
}

// The second plan extends the first, as the next turn of a conversation does.
func TestCacheDemandContinuationReportsFirstPlansEnd(t *testing.T) {
	t.Run("first_plan_ends_on_the_stride", func(t *testing.T) {
		f := newDemandStrideFixture(t)
		f.observe(4_097, 4_097, 1) // final boundary 4,096
		if repeat, _ := f.observe(9_000, 4_097, 2); repeat != 4_096 {
			t.Fatalf("continuation reported %d, want the first plan's final boundary 4,096", repeat)
		}
	})
	t.Run("first_plan_ends_between_strides", func(t *testing.T) {
		f := newDemandStrideFixture(t)
		f.observe(7_000, 7_000, 1) // final boundary 6,912
		// The continuation does not read 6,912. It reports the stride boundary
		// below it, which is the checkpoint the provider would choose for 6,912.
		if repeat, _ := f.observe(9_000, 7_000, 2); repeat != 6_144 {
			t.Fatalf("continuation reported %d, want 6,144", repeat)
		}
		// The turn after that extends the second plan, which ended at 8,960.
		if repeat, _ := f.observe(12_000, 7_000, 2); repeat != 8_192 {
			t.Fatalf("third turn reported %d, want 8,192", repeat)
		}
	})
}

func TestCacheDemandBoundsObservationsPerPlan(t *testing.T) {
	for _, tc := range []struct {
		tokens, want               int
		shallowest, window, finalB int
	}{
		{257, 1, 256, 256, 256},
		{1_024, 1, 768, 768, 768},
		{3_266, 3, 1_024, 1_024, 3_072},          // the gpt-oss median: final on the stride
		{7_000, 7, 1_024, 1_024, 6_912},          // six strides and a final between strides
		{65_537, 64, 1_024, 1_024, 65_536},       // exactly the window, final on its deepest stride
		{66_561, 65, 1_024, 2_048, 66_560},       // one stride more than the window: one rung below it
		{100_000, 71, 1_024, 34_816, 99_840},     // window, final and six rungs
		{131_072, 71, 1_024, 65_536, 130_816},    // 65,536 is the window's shallowest stride
		{200_000, 73, 1_024, 135_168, 199_936},   // eight rungs, 131,072 among them
		{1_000_001, 75, 1_024, 934_912, 999_936}, // the longest plan a receipt can name
	} {
		t.Run(fmt.Sprintf("tokens=%d", tc.tokens), func(t *testing.T) {
			f := newDemandStrideFixture(t)
			plan := demandTestPlan(f.generation, tc.tokens, 0, 1)
			anchors := cachedemand.Anchors(plan.Boundaries)
			if len(anchors) != tc.want || len(anchors) > cachedemand.MaxPlanBoundaries {
				t.Fatalf("selected %d anchors, want %d", len(anchors), tc.want)
			}
			final := plan.Boundaries[len(plan.Boundaries)-1]
			if anchors[len(anchors)-1] != final || final.TokenCount != tc.finalB || anchors[0].TokenCount != tc.shallowest {
				t.Fatalf("anchors span %d..%d, want %d..%d", anchors[0].TokenCount,
					anchors[len(anchors)-1].TokenCount, tc.shallowest, tc.finalB)
			}
			inWindow := 0
			for i, anchor := range anchors {
				if i > 0 && anchor.TokenCount <= anchors[i-1].TokenCount {
					t.Fatalf("anchors out of order at %d", i)
				}
				switch {
				case anchor == final && anchor.TokenCount%cachedemand.StrideTokens != 0:
				case anchor.TokenCount%cachedemand.StrideTokens != 0:
					t.Fatalf("anchor at %d tokens is neither on the stride nor final", anchor.TokenCount)
				case anchor.TokenCount >= tc.window:
					inWindow++
				case !cachedemand.AffinityRung(anchor.TokenCount):
					t.Fatalf("anchor at %d tokens is below the window and not a rung", anchor.TokenCount)
				}
			}
			if inWindow > cachedemand.MaxStrideBoundaries || (tc.tokens > 65_536 && inWindow != cachedemand.MaxStrideBoundaries) {
				t.Fatalf("window holds %d stride boundaries", inWindow)
			}
			f.observe(tc.tokens, 0, 1)
			if got := f.entries(); got != tc.want {
				t.Fatalf("recorded %d entries, want %d", got, tc.want)
			}
		})
	}
	if anchors := cachedemand.Anchors(nil); len(anchors) != 0 {
		t.Fatalf("an empty plan selected %+v", anchors)
	}
	if cachedemand.MaxPlanBoundaries != 75 {
		t.Fatalf("per-plan bound is %d", cachedemand.MaxPlanBoundaries)
	}
	for tokens, want := range map[int]bool{
		0: false, 256: false, 512: false, 768: false, 1_024: true, 2_048: true, 3_072: false,
		4_096: true, 6_144: false, 8_192: true, 65_536: true, 66_560: false, 524_288: true,
	} {
		if cachedemand.AffinityRung(tokens) != want {
			t.Fatalf("rung(%d) = %v", tokens, !want)
		}
	}
}

// The repeat stays as fine as the stride while the affinity key moves only
// when the shared prefix crosses a power-of-two multiple of 1,024 tokens. A
// key that followed the repeat changed the affinity winner on every stride
// the conversation crossed; on a turn without holder evidence that is a cold
// prefill on another provider and a duplicate checkpoint write.
func TestCacheDemandAffinityIsStickyWhileTheRepeatAdvances(t *testing.T) {
	for _, tc := range []struct {
		name               string
		start, growth      int
		turns              int
		repeats, keys      []int
		repeatMoves, moves int
	}{
		{
			name: "chat_400_per_turn", start: 5_000, growth: 400, turns: 11,
			repeats:     []int{0, 4_096, 5_120, 5_120, 6_144, 6_144, 6_144, 7_168, 7_168, 8_192, 8_192},
			keys:        []int{0, 4_096, 4_096, 4_096, 4_096, 4_096, 4_096, 4_096, 4_096, 8_192, 8_192},
			repeatMoves: 4, moves: 1,
		},
		{
			name: "agent_1500_per_turn", start: 3_000, growth: 1_500, turns: 9,
			repeats:     []int{0, 2_048, 4_096, 5_120, 7_168, 8_192, 10_240, 11_264, 13_312},
			keys:        []int{0, 2_048, 4_096, 4_096, 4_096, 8_192, 8_192, 8_192, 8_192},
			repeatMoves: 7, moves: 2,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newDemandStrideFixture(t)
			repeatMoves, moves, previousKey, previousRepeat := 0, 0, "", 0
			for turn := 0; turn < tc.turns; turn++ {
				tokens := tc.start + turn*tc.growth
				// Every turn extends the conversation: it shares all of it.
				plan := f.plan(tokens, tokens, 0)
				if plan.RepeatedPrefixTokens != tc.repeats[turn] || f.affinityTokens(plan) != tc.keys[turn] {
					t.Fatalf("turn %d at %d tokens: repeat=%d affinity boundary=%d, want %d and %d", turn, tokens,
						plan.RepeatedPrefixTokens, f.affinityTokens(plan), tc.repeats[turn], tc.keys[turn])
				}
				if turn > 1 {
					if plan.RepeatedPrefixTokens < previousRepeat {
						t.Fatalf("turn %d: repeat fell from %d to %d", turn, previousRepeat, plan.RepeatedPrefixTokens)
					}
					if plan.RepeatedPrefixTokens != previousRepeat {
						repeatMoves++
					}
					if plan.AffinityKey() != previousKey {
						moves++
					}
				}
				previousKey, previousRepeat = plan.AffinityKey(), plan.RepeatedPrefixTokens
			}
			if repeatMoves != tc.repeatMoves || moves != tc.moves {
				t.Fatalf("repeat advanced %d times and the affinity key changed %d times, want %d and %d",
					repeatMoves, moves, tc.repeatMoves, tc.moves)
			}
		})
	}
}

// The affinity key falls back to the deepest match when no rung matched.
func TestCacheDemandAffinityFallsBackToTheDeepestMatch(t *testing.T) {
	f := newDemandStrideFixture(t)
	f.plan(900, 900, 0)
	if again := f.plan(900, 900, 0); again.RepeatedPrefixTokens != 768 || f.affinityTokens(again) != 768 {
		t.Fatalf("short prompt: repeat=%d affinity boundary=%d, want its final boundary 768",
			again.RepeatedPrefixTokens, f.affinityTokens(again))
	}
	// A rung takes precedence over a deeper final boundary that also matched.
	f.plan(7_000, 7_000, 1)
	if again := f.plan(7_000, 7_000, 1); again.RepeatedPrefixTokens != 6_912 || f.affinityTokens(again) != 4_096 {
		t.Fatalf("identical prompt: repeat=%d affinity boundary=%d, want 6,912 and 4,096",
			again.RepeatedPrefixTokens, f.affinityTokens(again))
	}
	// The index can lose a plan's shallow entries first, because the cap and
	// expiry take the oldest. A stride that still matches keeps an affinity.
	d := newDemandFixture(8, time.Minute)
	now := time.Unix(1_700_000_000, 0)
	d.tracker.Observe([]cachedemand.Boundary{{Key: "stride-3072", Tokens: 3_072}}, now)
	repeat, key := d.tracker.Observe([]cachedemand.Boundary{{Key: "rung-2048", Tokens: 2_048}, {Key: "stride-3072", Tokens: 3_072}}, now.Add(time.Second))
	if repeat != 3_072 || key != "stride-3072" {
		t.Fatalf("repeat=%d key=%q, want the matched stride", repeat, key)
	}
	repeat, key = d.tracker.Observe([]cachedemand.Boundary{{Key: "rung-2048", Tokens: 2_048}, {Key: "stride-3072", Tokens: 3_072}}, now.Add(2*time.Second))
	if repeat != 3_072 || key != "rung-2048" {
		t.Fatalf("repeat=%d key=%q, want the repeat at the stride and the key at the rung", repeat, key)
	}
}

// Selection is by token count: a plan that lists only some boundaries, as
// hand-built plans do, observes the same ones a dense plan would.
func TestCacheDemandSelectionIgnoresListPosition(t *testing.T) {
	anchor := func(blocks int) protocol.PrefixCacheAnchor {
		return protocol.PrefixCacheAnchor{TokenCount: blocks * int(promptcontract.BlockSize), ChainHash: strings.Repeat("c", 64)}
	}
	sparse := []protocol.PrefixCacheAnchor{
		anchor(1), anchor(3), anchor(8), anchor(17),
	}
	anchors := cachedemand.Anchors(sparse)
	if len(anchors) != 2 || anchors[0] != sparse[2] || anchors[1] != sparse[3] {
		t.Fatalf("selected %+v, want the 2,048 stride boundary and the final one", anchors)
	}
}
