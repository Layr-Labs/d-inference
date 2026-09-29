package registry

import (
	"math"
	"testing"
	"time"
)

// The demand cap is sized for this plan rate over cacheRoutingSizingTTL.
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
	tracker := newCacheRoutingTracker(cacheRoutingSizingTTL, defaultCacheRoutingMaxHolders)
	key := []byte("0123456789abcdef0123456789abcdef")
	now := time.Unix(1_700_000_000, 0)
	for i := 0; i < plans; i++ {
		tokens := mix.promptTokensAt((float64(i) + 0.5) / float64(plans))
		plan := demandTestPlan(tracker, tokens, 0, uint32(i+1))
		tracker.observeCacheDemand(&plan, key, now)
		if plan.RepeatedPrefixTokens != 0 {
			t.Fatalf("distinct plan %d reported a repeat of %d", i, plan.RepeatedPrefixTokens)
		}
	}
	entries := len(tracker.demand.entries)
	if entries >= cacheDemandMaxEntries {
		t.Fatalf("sample filled the index; use fewer than %d plans", plans)
	}
	return float64(entries) / float64(plans)
}

// The cap must hold every boundary that 60 plans a second record within the
// sizing TTL when no two prompts share a prefix, which is the worst case:
// shared prefixes record the same keys once.
func TestCacheDemandCapCoversMeasuredPlanMix(t *testing.T) {
	seconds := cacheRoutingSizingTTL.Seconds()
	worst := 0.0
	for _, mix := range demandPromptMixes {
		mean := measureDemandEntriesPerPlan(t, mix, 20_000)
		needed := demandSizingPlansPerSecond * seconds * mean
		t.Logf("%s: %.2f entries per plan, %.0f entries/s, %.0f entries over %s, cap %d is %.2fx",
			mix.name, mean, demandSizingPlansPerSecond*mean, needed, cacheRoutingSizingTTL,
			cacheDemandMaxEntries, float64(cacheDemandMaxEntries)/needed)
		worst = max(worst, needed)
	}
	if headroom := float64(cacheDemandMaxEntries) / worst; headroom < 1.15 {
		t.Fatalf("demand cap %d is %.2fx the %.0f entries the heaviest mix records in %s; want at least 1.15x",
			cacheDemandMaxEntries, headroom, worst, cacheRoutingSizingTTL)
	}
}

// demandStridePlan lists only what a plan of that length observes: its
// boundaries on the 1,024-token stride and its final one. Selection is by
// token count (TestCacheDemandSelectionIgnoresListPosition), so it records
// what the dense plan does at a quarter of the construction cost.
func demandStridePlan(tracker *cacheRoutingTracker, promptTokens int, variant uint32) CachePlan {
	dense := demandTestPlan(tracker, promptTokens, 0, variant)
	dense.Boundaries = cacheDemandAnchors(dense.Boundaries)
	return dense
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
	tracker := newCacheRoutingTracker(cacheRoutingSizingTTL, defaultCacheRoutingMaxHolders)
	start := time.Unix(1_700_000_000, 0)
	target := demandTestPlan(tracker, targetTokens, targetTokens, 0)
	tracker.observeCacheDemand(&target, key, start)
	now := start
	for i := 0; i < demandSizingPlansPerSecond*60*fillMinutes; i++ {
		now = now.Add(time.Second / demandSizingPlansPerSecond)
		// A low-discrepancy walk over the quantiles keeps every stretch of
		// the fill representative of the mix.
		_, q := math.Modf((float64(i) + 0.5) * 0.6180339887498949)
		plan := demandStridePlan(tracker, mix.promptTokensAt(q), uint32(i+1))
		tracker.observeCacheDemand(&plan, key, now)
	}
	if age := now.Sub(start); age < 28*time.Minute+59*time.Second || age >= cacheRoutingSizingTTL {
		t.Fatalf("fill covered %s, want just under %d minutes", age, fillMinutes)
	}
	recorded := len(tracker.demand.entries)
	if recorded <= formerCap || recorded >= cacheDemandMaxEntries {
		t.Fatalf("fill recorded %d entries; the test needs more than %d and fewer than %d",
			recorded, formerCap, cacheDemandMaxEntries)
	}
	again := demandTestPlan(tracker, targetTokens, targetTokens, 0)
	tracker.observeCacheDemand(&again, key, now)
	if again.RepeatedPrefixTokens != 6_912 || again.affinityKey == "" {
		t.Fatalf("plan observed %s earlier reported %d, want its final boundary 6,912 (index holds %d entries)",
			now.Sub(start), again.RepeatedPrefixTokens, recorded)
	}
}
