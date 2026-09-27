package registry

import (
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// demandTestPlan is a plan as the sidecar emits it: one boundary per complete
// 256-token block below the prompt length. Blocks that lie wholly inside the
// first sharedTokens tokens carry the shared chain; deeper ones are unique to
// the variant.
func demandTestPlan(tracker *cacheRoutingTracker, promptTokens, sharedTokens int, variant uint32) CachePlan {
	block := int(promptcontract.BlockSize)
	count := 0
	if promptTokens > 0 {
		count = (promptTokens - 1) / block
	}
	boundaries := make([]protocol.PrefixCacheAnchor, count)
	var digest [32]byte
	for i := range boundaries {
		tokens := (i + 1) * block
		chain := uint32(0)
		if tokens > sharedTokens {
			chain = variant
		}
		binary.BigEndian.PutUint32(digest[24:], chain)
		binary.BigEndian.PutUint32(digest[28:], uint32(i+1))
		boundaries[i] = protocol.PrefixCacheAnchor{TokenCount: tokens, ChainHash: hex.EncodeToString(digest[:])}
	}
	plan := exactTestPlan(boundaries...)
	plan.PromptTokenCount = promptTokens
	plan.generation = tracker.generation
	return plan
}

type demandStrideFixture struct {
	t       *testing.T
	tracker *cacheRoutingTracker
	key     []byte
	now     time.Time
}

func newDemandStrideFixture(t *testing.T) *demandStrideFixture {
	return &demandStrideFixture{
		t: t, tracker: newCacheRoutingTracker(cacheRoutingSizingTTL, defaultCacheRoutingMaxHolders),
		key: []byte("0123456789abcdef0123456789abcdef"), now: time.Unix(1_700_000_000, 0),
	}
}

// observe plans a prompt a second after the previous one and returns the
// repeat it reports and whether it produced an affinity key.
func (f *demandStrideFixture) observe(promptTokens, sharedTokens int, variant uint32) (int, bool) {
	f.t.Helper()
	plan := demandTestPlan(f.tracker, promptTokens, sharedTokens, variant)
	f.now = f.now.Add(time.Second)
	f.tracker.observeCacheDemand(&plan, f.key, f.now)
	if (plan.RepeatedPrefixTokens > 0) != (plan.affinityKey != "") {
		f.t.Fatalf("repeat=%d but affinity key present=%v", plan.RepeatedPrefixTokens, plan.affinityKey != "")
	}
	return plan.RepeatedPrefixTokens, plan.affinityKey != ""
}

func (f *demandStrideFixture) entries() int {
	f.tracker.demand.mu.Lock()
	defer f.tracker.demand.mu.Unlock()
	return len(f.tracker.demand.entries)
}

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
		tokens, want       int
		shallowest, finalB int
	}{
		{100_000, 65, 34_816, 99_840},  // 97 strides available, final between strides
		{65_537, 64, 1_024, 65_536},    // exactly 64 strides, final on the last one
		{66_561, 64, 2_048, 66_560},    // 65 strides available, final on the deepest
		{131_072, 65, 65_536, 130_816}, // the longest plan the sizing assumes
		{3_266, 3, 1_024, 3_072},       // the gpt-oss median: final on the stride
		{7_000, 7, 1_024, 6_912},       // six strides and a final between strides
		{1_024, 1, 768, 768},
		{257, 1, 256, 256},
	} {
		t.Run(fmt.Sprintf("tokens=%d", tc.tokens), func(t *testing.T) {
			f := newDemandStrideFixture(t)
			plan := demandTestPlan(f.tracker, tc.tokens, 0, 1)
			anchors := cacheDemandAnchors(plan.Boundaries)
			if len(anchors) != tc.want || len(anchors) > cacheDemandMaxStrideBoundaries+1 {
				t.Fatalf("selected %d anchors, want %d", len(anchors), tc.want)
			}
			final := plan.Boundaries[len(plan.Boundaries)-1]
			if anchors[len(anchors)-1] != final {
				t.Fatalf("deepest anchor %+v is not the final boundary %+v", anchors[len(anchors)-1], final)
			}
			if anchors[0].TokenCount != tc.shallowest || final.TokenCount != tc.finalB {
				t.Fatalf("anchors span %d..%d, want %d..%d", anchors[0].TokenCount, final.TokenCount, tc.shallowest, tc.finalB)
			}
			for i, anchor := range anchors {
				if i > 0 && anchor.TokenCount <= anchors[i-1].TokenCount {
					t.Fatalf("anchors out of order at %d: %+v", i, anchors)
				}
				if anchor != final && anchor.TokenCount%cacheDemandStrideTokens != 0 {
					t.Fatalf("anchor at %d tokens is neither on the stride nor final", anchor.TokenCount)
				}
			}
			f.observe(tc.tokens, 0, 1)
			if got := f.entries(); got != tc.want {
				t.Fatalf("recorded %d entries, want %d", got, tc.want)
			}
		})
	}
	if anchors := cacheDemandAnchors(nil); len(anchors) != 0 {
		t.Fatalf("an empty plan selected %+v", anchors)
	}
}

// Selection is by token count: a plan that lists only some boundaries, as
// hand-built plans do, observes the same ones a dense plan would.
func TestCacheDemandSelectionIgnoresListPosition(t *testing.T) {
	sparse := []protocol.PrefixCacheAnchor{
		exactTestAnchor(1, "c"), exactTestAnchor(3, "c"), exactTestAnchor(8, "c"), exactTestAnchor(17, "c"),
	}
	anchors := cacheDemandAnchors(sparse)
	if len(anchors) != 2 || anchors[0] != sparse[2] || anchors[1] != sparse[3] {
		t.Fatalf("selected %+v, want the 2,048 stride boundary and the final one", anchors)
	}
}
