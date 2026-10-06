package registry_test

import (
	"encoding/binary"
	"encoding/hex"
	"math"
	"reflect"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachedemand"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheplan"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachepolicy"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// The demand cap is sized for this plan rate over cachedemand.SizingTTL.
const demandSizingPlansPerSecond = 60

// demandPromptMix is a model's production prompt-length distribution in
// tokens, as measured quantiles.
type demandPromptMix struct {
	name               string
	p25, p50, p75, p90 float64
}

var demandPromptMixes = []demandPromptMix{
	{"gpt-oss-20b", 1_636, 3_266, 6_509, 14_822},
	{"gemma", 587, 2_256, 3_707, 5_974},
}

// promptTokensAt interpolates the quantile function linearly through the
// measured points, which puts more mass on long prompts than a log-linear
// fit would. The tails are assumptions: the shortest plan has one boundary
// (257 tokens), p99 is three times p90, and the longest prompt is 131,072
// tokens.
func (m demandPromptMix) promptTokensAt(q float64) int {
	points := [][2]float64{
		{0, 257}, {0.25, m.p25}, {0.50, m.p50}, {0.75, m.p75}, {0.90, m.p90},
		{0.99, 3 * m.p90}, {1, 131_072},
	}
	for i := 1; i < len(points); i++ {
		if q <= points[i][0] {
			low, high := points[i-1], points[i]
			return int(math.Round(low[1] + (high[1]-low[1])*(q-low[0])/(high[0]-low[0])))
		}
	}
	return 131_072
}

// measureDemandEntriesPerPlan plans a stratified sample of the mix through
// the real observation path, every prompt distinct, and divides what the
// index then holds by the number of plans.
func measureDemandEntriesPerPlan(t testing.TB, mix demandPromptMix, plans int) float64 {
	t.Helper()
	generation := &cacheplan.Generation{}
	demand := newDemandFixture(cachedemand.MaxEntries, cachedemand.SizingTTL)
	key := []byte("0123456789abcdef0123456789abcdef")
	now := time.Unix(1_700_000_000, 0)
	for i := 0; i < plans; i++ {
		tokens := mix.promptTokensAt((float64(i) + 0.5) / float64(plans))
		plan := demandTestPlan(generation, tokens, 0, uint32(i+1))
		plan.ObserveRouteDemand(generation, demand.tracker, key, now, 0)
		if plan.RepeatedPrefixTokens != 0 {
			t.Fatalf("distinct plan %d reported a repeat of %d", i, plan.RepeatedPrefixTokens)
		}
	}
	entries := demand.index.Len()
	if entries >= cachedemand.MaxEntries {
		t.Fatalf("sample filled the index; use fewer than %d plans", plans)
	}
	return float64(entries) / float64(plans)
}

// The cap must hold every boundary that 60 plans a second record within the
// sizing TTL when no two prompts share a prefix, which is the worst case:
// shared prefixes record the same keys once.
func TestCacheDemandCapCoversMeasuredPlanMix(t *testing.T) {
	seconds := cachedemand.SizingTTL.Seconds()
	worst := 0.0
	for _, mix := range demandPromptMixes {
		mean := measureDemandEntriesPerPlan(t, mix, 20_000)
		needed := demandSizingPlansPerSecond * seconds * mean
		t.Logf("%s: %.2f entries per plan, %.0f entries/s, %.0f entries over %s, cap %d is %.2fx",
			mix.name, mean, demandSizingPlansPerSecond*mean, needed, cachedemand.SizingTTL,
			cachedemand.MaxEntries, float64(cachedemand.MaxEntries)/needed)
		worst = max(worst, needed)
	}
	if headroom := float64(cachedemand.MaxEntries) / worst; headroom < 1.15 {
		t.Fatalf("demand cap %d is %.2fx the %.0f entries the heaviest mix records in %s; want at least 1.15x",
			cachedemand.MaxEntries, headroom, worst, cachedemand.SizingTTL)
	}
}

// demandStridePlan lists only what a plan of that length observes: its
// boundaries on the 1,024-token stride and its final one. Selection is by
// token count (TestCacheDemandSelectionIgnoresListPosition), so hashes only
// need encoding after selection.
func demandStridePlan(generation *cacheplan.Generation, promptTokens int, variant uint32) cacheplan.Plan {
	block := int(promptcontract.BlockSize)
	count := 0
	if promptTokens > 0 {
		count = (promptTokens - 1) / block
	}
	boundaries := make([]protocol.PrefixCacheAnchor, count)
	for i := range boundaries {
		boundaries[i].TokenCount = (i + 1) * block
	}
	boundaries = cachedemand.Anchors(boundaries)
	var digest [32]byte
	binary.BigEndian.PutUint32(digest[24:], variant)
	for i := range boundaries {
		// The digest names the original dense block, not its selected position.
		binary.BigEndian.PutUint32(digest[28:], uint32(boundaries[i].TokenCount/block))
		boundaries[i].ChainHash = hex.EncodeToString(digest[:])
	}
	plan := demandPlanValue(boundaries...)
	plan.PromptTokenCount = promptTokens
	plan = bindDemandPlan(generation, plan)
	return plan
}

func TestCacheDemandStridePlanMatchesDensePlan(t *testing.T) {
	generation := &cacheplan.Generation{}
	block := int(promptcontract.BlockSize)
	check := func(tokens int, variant uint32) {
		t.Helper()
		dense := demandTestPlan(generation, tokens, 0, variant)
		dense.Boundaries = cachedemand.Anchors(dense.Boundaries)
		sparse := demandStridePlan(generation, tokens, variant)
		if !reflect.DeepEqual(sparse, dense) || sparse.Provenance() != dense.Provenance() {
			t.Fatalf("tokens=%d variant=%d: sparse plan %+v differs from dense plan %+v", tokens, variant, sparse, dense)
		}
	}
	// These plan fixtures require at least one boundary. Cover every supported
	// nonempty block count, including the stride window and ladder.
	for count := 1; count <= cachepolicy.MaxReceiptTokens/block; count++ {
		check(count*block+1, uint32(count)*0x01010101)
	}
	for _, tokens := range []int{block + 1, 2*block - 1, 2 * block, 2*block + 1, cachepolicy.MaxReceiptTokens, cachepolicy.MaxReceiptTokens + 1} {
		for _, variant := range []uint32{0, 1, 0x12345678, ^uint32(0)} {
			check(tokens, variant)
		}
	}
}

// A plan observed 29 minutes ago still reports its repeat while the
// production mix arrives at the sizing rate, every prompt distinct. The fill
// records more than the former 600,000-entry cap held, which
// TestCacheDemandRetainsBoundaryFor29MinutesAtSizingRate shows turning over.
func TestCacheDemandRetainsPlanFor29MinutesAtSizingRate(t *testing.T) {
	if testing.Short() {
		t.Skip("plans 104,400 prompts")
	}
	const fillMinutes, formerCap, targetTokens = 29, 600_000, 7_000
	mix := demandPromptMixes[0]
	key := []byte("0123456789abcdef0123456789abcdef")
	generation := &cacheplan.Generation{}
	demand := newDemandFixture(cachedemand.MaxEntries, cachedemand.SizingTTL)
	start := time.Unix(1_700_000_000, 0)
	target := demandTestPlan(generation, targetTokens, targetTokens, 0)
	target.ObserveRouteDemand(generation, demand.tracker, key, start, 0)
	now := start
	for i := 0; i < demandSizingPlansPerSecond*60*fillMinutes; i++ {
		now = now.Add(time.Second / demandSizingPlansPerSecond)
		// A low-discrepancy walk over the quantiles keeps every stretch of
		// the fill representative of the mix.
		_, q := math.Modf((float64(i) + 0.5) * 0.6180339887498949)
		plan := demandStridePlan(generation, mix.promptTokensAt(q), uint32(i+1))
		plan.ObserveRouteDemand(generation, demand.tracker, key, now, 0)
	}
	if age := now.Sub(start); age < 28*time.Minute+59*time.Second || age >= cachedemand.SizingTTL {
		t.Fatalf("fill covered %s, want just under %d minutes", age, fillMinutes)
	}
	recorded := demand.index.Len()
	if recorded <= formerCap || recorded >= cachedemand.MaxEntries {
		t.Fatalf("fill recorded %d entries; the test needs more than %d and fewer than %d",
			recorded, formerCap, cachedemand.MaxEntries)
	}
	again := demandTestPlan(generation, targetTokens, targetTokens, 0)
	again.ObserveRouteDemand(generation, demand.tracker, key, now, 0)
	if again.RepeatedPrefixTokens != 6_912 || again.AffinityKey() == "" {
		t.Fatalf("plan observed %s earlier reported %d, want its final boundary 6,912 (index holds %d entries)",
			now.Sub(start), again.RepeatedPrefixTokens, recorded)
	}
}
