package registry

import (
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

type stageMeasurementFixture struct {
	r          *Registry
	p          *Provider
	capability protocol.PrefixCacheV2Capability
	plan       CachePlan
	checkpoint protocol.PrefixCacheAnchor
}

func newStageMeasurementFixture(t *testing.T) stageMeasurementFixture {
	t.Helper()
	r, _, _ := exactTestRegistry(t)
	removeTestProvider(r, "provider-a")
	capability := indexTestCapability(1)
	p := checkpointTestProvider(t, r, "ssd", capability)
	checkpoint := exactTestAnchor(16, "c")
	return stageMeasurementFixture{r: r, p: p, capability: capability,
		plan: boundTestCachePlan(r, exactTestPlan(checkpoint)), checkpoint: checkpoint}
}

// Production Prepare and validated receipt handlers, with only their clock
// injected. Donors can precede another request's measured hit.
func (f stageMeasurementFixture) lookup(t *testing.T, id string, seq uint64, outcome string, stage float64, now time.Time) *protocol.PrefixCacheReadyV2Message {
	t.Helper()
	pr := &PendingRequest{RequestID: id, Model: "model", CachePlan: f.plan}
	if err := prepareBoundTestCacheAttempt(f.r, pr, f.p); err != nil {
		t.Fatal(err)
	}
	nonce := preparedTestCacheMetadata(pr).CacheReceiptNonce
	prompt := f.plan.Boundaries[len(f.plan.Boundaries)-1]
	lookup := testV2Lookup(nonce, f.capability, prompt, seq)
	lookup.RequestID, lookup.Outcome, lookup.StageMs = id, outcome, stage
	if outcome == "hit" {
		lookup.MatchedAnchor = &f.checkpoint
		lookup.ExpectedPrefillTokensSaved = f.checkpoint.TokenCount
	}
	accepted, mismatch := f.r.cacheRouting.applyLookupV2Result(f.p.ID, f.p, f.capability, lookup, f.r.cacheRouteKeys.route, now)
	if !accepted || mismatch {
		t.Fatalf("lookup %s accepted=%v mismatch=%v", id, accepted, mismatch)
	}
	ready := testV2Ready(nonce, f.capability, f.checkpoint, seq+1)
	ready.RequestID = id
	return ready
}

func (f stageMeasurementFixture) ready(t *testing.T, ready *protocol.PrefixCacheReadyV2Message, seq uint64, stage float64, now time.Time) {
	t.Helper()
	ready.CacheSeq, ready.StageMs = seq, stage
	accepted, mismatch := f.r.cacheRouting.applyReadyV2Result(f.p.ID, f.p, f.capability, ready, f.r.cacheRouteKeys.route, now)
	if !accepted || mismatch {
		t.Fatalf("ready accepted=%v mismatch=%v", accepted, mismatch)
	}
}

func (f stageMeasurementFixture) stage(t *testing.T, now time.Time) float64 {
	t.Helper()
	hints := memoryTestHints(f.r, f.plan, now)
	if len(hints) != 1 {
		t.Fatalf("expected one holder: %+v", hints)
	}
	return hints[f.p.ID].StageMs
}

func TestSSDMeasuredStageSurvivesReadyAndChangesRouting(t *testing.T) {
	for _, tc := range []struct {
		name               string
		measured, estimate float64
		winner             string
	}{
		{"slow_read_not_erased", 900, 100, "cold"}, {"fast_read_not_overpriced", 100, 900, "ssd"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newStageMeasurementFixture(t)
			f.r.cacheRoutingMaxDiscountMs, f.r.cacheRoutingMaxCostFraction = nil, nil
			f.p.mu.Lock()
			f.p.PrefillTPS = 5000
			f.p.BackendCapacity.Slots[0].ObservedPrefillTPS = 5000
			f.p.mu.Unlock()
			cold := makeSchedulerProvider(t, f.r, "cold", "model", 100)
			cold.mu.Lock()
			cold.PrefillTPS = 4800
			cold.BackendCapacity.Slots[0].ObservedPrefillTPS = 4800
			cold.mu.Unlock()
			now := time.Now()
			donor := f.lookup(t, "cold-donor", 1, "miss_absent", 1, now)
			f.lookup(t, "measured-reader", 2, "hit", tc.measured, now)
			f.ready(t, donor, 3, tc.estimate, now)
			if got := f.stage(t, now); got != tc.measured {
				t.Errorf("Ready replaced measured stage: got %v want %v", got, tc.measured)
			}
			request := &PendingRequest{RequestID: "repeat", Model: "model", CachePlan: f.plan, EstimatedPromptTokens: f.plan.PromptTokenCount, RequestedMaxTokens: 128}
			selected, decision := f.r.ReserveProviderEx("model", request)
			if selected == nil || selected.ID != tc.winner || decision.SelectionPath != SelectionUniqueMin {
				t.Fatalf("want %s: selected=%v decision=%+v", tc.winner, selected, decision)
			}
			selected.RemovePending(request.RequestID)
			f.r.SetProviderIdle(selected.ID)
		})
	}
}

func TestSSDReadyDoesNotExtendMeasuredStageDeadline(t *testing.T) {
	f := newStageMeasurementFixture(t)
	f.r.cacheRouting.ttl = time.Minute
	now := time.Now()
	first := f.lookup(t, "first-donor", 1, "miss_absent", 1, now)
	second := f.lookup(t, "second-donor", 2, "miss_absent", 1, now)
	f.lookup(t, "reader", 3, "hit", 900, now)
	f.ready(t, first, 4, 100, now.Add(30*time.Second))
	f.ready(t, second, 5, 200, now.Add(50*time.Second))
	if got := f.stage(t, now.Add(time.Minute-time.Nanosecond)); got != 900 {
		t.Fatalf("early expiry: %v", got)
	}
	if got := f.stage(t, now.Add(time.Minute)); got != 200 {
		t.Fatalf("measurement extended or latest fallback lost: %v", got)
	}
	if got := f.stage(t, now.Add(100*time.Second)); got != 200 {
		t.Fatalf("expired measurement returned: %v", got)
	}
	if hints := memoryTestHints(f.r, f.plan, now.Add(110*time.Second)); len(hints) != 0 {
		t.Fatal("holder survived normal TTL")
	}
}

func TestSSDNewLookupReplacesPreviousMeasurement(t *testing.T) {
	f := newStageMeasurementFixture(t)
	f.r.cacheRouting.ttl = time.Minute
	now := time.Now()
	first := f.lookup(t, "first-donor", 1, "miss_absent", 1, now)
	second := f.lookup(t, "second-donor", 2, "miss_absent", 1, now)
	f.lookup(t, "slow-reader", 3, "hit", 900, now)
	f.ready(t, first, 4, 100, now.Add(10*time.Second))
	f.lookup(t, "fast-reader", 5, "hit", 50, now.Add(40*time.Second))
	f.ready(t, second, 6, 200, now.Add(50*time.Second))
	if got := f.stage(t, now.Add(70*time.Second)); got != 50 {
		t.Fatalf("new lookup lost fresh deadline: %v", got)
	}
	if got := f.stage(t, now.Add(100*time.Second)); got != 200 {
		t.Fatalf("new measurement did not expire: %v", got)
	}
}

func TestSSDMeasurementStaysAtExactEndpoint(t *testing.T) {
	f := newStageMeasurementFixture(t)
	long := exactTestAnchor(32, "d")
	f.plan = boundTestCachePlan(f.r, exactTestPlan(f.checkpoint, long))
	now := time.Now()
	donor := f.lookup(t, "donor", 1, "miss_absent", 1, now)
	f.lookup(t, "short-reader", 2, "hit", 900, now)
	donor.ReadyAnchors = []protocol.PrefixCacheAnchor{f.checkpoint, long}
	donor.ExpectedPrefillTokensSaved = long.TokenCount
	f.ready(t, donor, 3, 200, now)
	if got := f.stage(t, now); got != 200 {
		t.Fatalf("measurement leaked to longer endpoint: %v", got)
	}
	f.plan = boundTestCachePlan(f.r, exactTestPlan(f.checkpoint))
	if got := f.stage(t, now); got != 900 {
		t.Fatalf("short endpoint lost measurement: %v", got)
	}
}

func TestSSDMeasurementDoesNotCrossCapabilityOrConnection(t *testing.T) {
	for _, change := range []string{"epoch", "boundary_mode", "connection", "reconfigure", "scope", "recompute", "holder_expired", "miss", "eviction"} {
		t.Run(change, func(t *testing.T) {
			f := newStageMeasurementFixture(t)
			now := time.Now()
			if change == "recompute" {
				f.capability.ReadyBoundaryMode = ""
				f.p.PrefixCacheV2Models["model"] = f.capability
			}
			f.lookup(t, "reader", 1, "hit", 900, now)
			seq := uint64(2)
			switch change {
			case "epoch", "boundary_mode":
				// Capability publication may precede tracker cleanup. Exercise that
				// window deterministically without a serving-path test hook.
				if change == "epoch" {
					f.capability.CacheEpoch = indexTestCapability(99).CacheEpoch
				} else {
					f.capability.ReadyBoundaryMode = ""
				}
				f.p.mu.Lock()
				f.p.PrefixCacheV2Models["model"] = f.capability
				f.p.prefixCacheRevision++
				f.p.mu.Unlock()
			case "connection":
				removeTestProvider(f.r, f.p.ID)
				f.p = checkpointTestProvider(t, f.r, "ssd", f.capability)
			case "reconfigure":
				if err := f.r.ConfigureCacheRouting(generationTestConfig(CacheRoutingOn)); err != nil {
					t.Fatal(err)
				}
				f.plan = boundTestCachePlan(f.r, exactTestPlan(f.checkpoint))
			case "scope":
				f.plan.CacheScope = "different-account-scope"
			case "holder_expired":
				now = now.Add(f.r.cacheRouting.ttl)
			case "miss":
				f.lookup(t, "missing", seq, "miss_absent", 1, now)
				seq++
			case "eviction":
				f.r.cacheRouting.mu.Lock()
				key := cacheTierBoundaryKey(f.r.cacheRouteKeys.route, f.plan, f.checkpoint, "ssd")
				f.r.cacheRouting.removeHolderLocked(key, f.p.ID, cacheHolderRemovalCapacityEviction)
				f.r.cacheRouting.mu.Unlock()
			}
			// A skipped lookup does not erase old holder evidence as a miss would.
			donor := f.lookup(t, "new-donor", seq, "skipped_policy", 1, now)
			if change == "recompute" {
				donor.RequiredRecomputeTokens = 128
				donor.ExpectedPrefillTokensSaved -= 128
			}
			f.ready(t, donor, seq+1, 100, now)
			if got := f.stage(t, now); got != 100 {
				t.Fatalf("measurement crossed %s: %v", change, got)
			}
		})
	}
}

func TestSSDStageMeasurementConcurrentQueryAndReady(t *testing.T) {
	f := newStageMeasurementFixture(t)
	now := time.Now()
	const count = 32
	donors := make([]*protocol.PrefixCacheReadyV2Message, count)
	for i := range donors {
		donors[i] = f.lookup(t, fmt.Sprintf("donor-%d", i), uint64(i+1), "miss_absent", 1, now)
	}
	f.lookup(t, "reader", count+1, "hit", 900, now)
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < count*8; i++ {
			if got := f.stage(t, now); got != 900 {
				t.Errorf("query lost measurement: %v", got)
				return
			}
		}
	}()
	for i, donor := range donors {
		f.ready(t, donor, uint64(count+i+2), 100, now)
	}
	wg.Wait()
}

// A routing round captures one query time; a later refresh must not mutate
// the selected sample through the immutable observation shared by holders.
func TestSSDStageHintFreezesQueryObservation(t *testing.T) {
	f := newStageMeasurementFixture(t)
	f.r.cacheRouting.ttl = time.Minute
	now := time.Now()
	donor := f.lookup(t, "donor", 1, "miss_absent", 1, now)
	f.lookup(t, "reader", 2, "hit", 900, now)
	f.ready(t, donor, 3, 100, now.Add(30*time.Second))
	hints := memoryTestHints(f.r, f.plan, now.Add(59*time.Second))
	if got := f.stage(t, now.Add(time.Minute)); got != 100 {
		t.Fatalf("fresh query ignored expiry: %v", got)
	}
	if hints[f.p.ID].StageMs != 900 || !hints[f.p.ID].currentForProvider(f.p, "model") {
		t.Fatal("captured query observation changed")
	}
}

func TestSSDMeasuredStageQueryFencesCapabilityPublication(t *testing.T) {
	for _, expired := range []bool{false, true} {
		t.Run(fmt.Sprintf("expired=%v", expired), func(t *testing.T) {
			f := newStageMeasurementFixture(t)
			f.r.cacheRouting.ttl = time.Minute
			now := time.Now()
			donor := f.lookup(t, "old-donor", 1, "miss_absent", 1, now)
			f.lookup(t, "reader", 2, "hit", 900, now)
			f.ready(t, donor, 3, 100, now.Add(30*time.Second))
			queryTime := now.Add(40 * time.Second)
			if expired {
				queryTime = now.Add(time.Minute)
			}
			// Same epoch/connection/anchor; the full capability changes before tracker
			// cleanup. A query must refuse the old holder before any replacement Ready.
			f.capability.ReadyBoundaryMode = ""
			f.p.mu.Lock()
			f.p.PrefixCacheV2Models["model"] = f.capability
			f.p.prefixCacheRevision++
			f.p.mu.Unlock()
			if hints := memoryTestHints(f.r, f.plan, queryTime); len(hints) != 0 {
				t.Fatalf("old execution-contract cost survived capability publication: %+v", hints)
			}
			current := f.lookup(t, "current-donor", 4, "skipped_policy", 1, queryTime)
			f.ready(t, current, 5, 150, queryTime)
			if got := f.stage(t, queryTime); got != 150 {
				t.Fatalf("new valid Ready did not establish current fallback: %v", got)
			}
		})
	}
}
