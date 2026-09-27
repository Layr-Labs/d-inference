package registry

import (
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

type fenceTestClock struct {
	mu  sync.Mutex
	now time.Time
}

func newFenceTestClock() *fenceTestClock {
	return &fenceTestClock{now: time.Date(2026, 9, 26, 12, 0, 0, 0, time.UTC)}
}

func (c *fenceTestClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *fenceTestClock) Advance(d time.Duration) {
	c.mu.Lock()
	c.now = c.now.Add(d)
	c.mu.Unlock()
}

// fenceTestRegistry keeps holders alive across every fence window under test
// (10 min cap, twice) so expiry is attributable to the fence alone.
func fenceTestRegistry(t *testing.T) (*Registry, *Provider, protocol.PrefixCacheV2Capability, *fenceTestClock) {
	t.Helper()
	r, provider, capability := exactTestRegistryWithTTL(t, 2*time.Hour)
	clock := newFenceTestClock()
	r.SetCacheRoutingClockForTest(clock.Now)
	return r, provider, capability, clock
}

// fenceTestLookup prepares a fresh attempt for the plan and returns a lookup
// receipt whose prompt anchor carries the given chain hash. The plan's own
// hash yields a valid proof; any other hash is a prompt mismatch.
func fenceTestLookup(
	t *testing.T, r *Registry, provider *Provider,
	capability protocol.PrefixCacheV2Capability,
	id string, plan CachePlan, hash string, seq uint64,
) *protocol.PrefixCacheLookupV2Message {
	t.Helper()
	pr := &PendingRequest{RequestID: id, Model: "model", CachePlan: plan}
	if err := prepareBoundTestCacheAttempt(r, pr, provider); err != nil {
		t.Fatal(err)
	}
	nonce := preparedTestCacheMetadata(pr).CacheReceiptNonce
	if nonce == "" {
		t.Fatalf("attempt %s was not prepared", id)
	}
	prompt := plan.Boundaries[len(plan.Boundaries)-1]
	prompt.ChainHash = hash
	return &protocol.PrefixCacheLookupV2Message{
		RequestID: id, CacheReceiptNonce: nonce,
		ModelID: "model", ModelAggregateHash: capability.ModelAggregateHash,
		PromptContractID: capability.PromptContractID, CacheEpoch: capability.CacheEpoch,
		CacheSeq: seq, PromptAnchor: prompt, Outcome: "miss_absent", Tier: "ssd", StageMs: 1,
	}
}

func fenceTestCapabilityReason(r *Registry, provider *Provider) CacheReceiptReason {
	_, reason := r.currentPrefixCacheV2CapabilityResult(provider.ID, "model", "ssd")
	return reason
}

func TestProofFenceExpiresAndAcceptsLaterProof(t *testing.T) {
	r, provider, capability, clock := fenceTestRegistry(t)
	plan := exactTestPlan(exactTestAnchor(1, "c"))
	valid := plan.Boundaries[0].ChainHash
	seq := uint64(0)
	next := func() uint64 { seq++; return seq }

	mismatch := fenceTestLookup(t, r, provider, capability, "mismatch", plan, strings.Repeat("d", 64), next())
	if got := r.ApplyPrefixCacheLookupV2Result(provider.ID, mismatch); got.Accepted || got.Reason != CacheReceiptPromptMismatch {
		t.Fatalf("mismatch decision=%+v", got)
	}
	if reason := fenceTestCapabilityReason(r, provider); reason != CacheReceiptCapabilityFenced {
		t.Fatalf("capability after mismatch = %s, want fenced", reason)
	}
	if status := r.CacheRoutingLifecycleStatus(); status.FencesApplied != 1 || status.FencesExpired != 0 || status.FencedCapabilities != 1 {
		t.Fatalf("lifecycle after mismatch = %+v", status)
	}

	clock.Advance(cacheProofFenceBase - time.Second)
	early := fenceTestLookup(t, r, provider, capability, "early", plan, valid, next())
	if got := r.ApplyPrefixCacheLookupV2Result(provider.ID, early); got.Accepted || got.Reason != CacheReceiptCapabilityFenced {
		t.Fatalf("receipt one second before expiry = %+v, want fenced", got)
	}

	clock.Advance(time.Second)
	if reason := fenceTestCapabilityReason(r, provider); reason != CacheReceiptAccepted {
		t.Fatalf("capability at expiry = %s, want accepted", reason)
	}
	late := fenceTestLookup(t, r, provider, capability, "late", plan, valid, next())
	if got := r.ApplyPrefixCacheLookupV2Result(provider.ID, late); !got.Accepted {
		t.Fatalf("valid proof after expiry = %+v, want accepted", got)
	}
	status := r.CacheRoutingLifecycleStatus()
	if status.FencesApplied != 1 || status.FencesExpired != 1 || status.FencedCapabilities != 0 {
		t.Fatalf("lifecycle after expiry = %+v", status)
	}
	r.cacheRouting.mu.Lock()
	remaining := len(r.cacheRouting.rejectedV2)
	r.cacheRouting.mu.Unlock()
	if remaining != 0 {
		t.Fatal("accepted proof after expiry retained the fence record")
	}
}

func TestProofFenceDoublesOnConsecutiveMismatchesUpToCap(t *testing.T) {
	r, provider, capability, clock := fenceTestRegistry(t)
	plan := exactTestPlan(exactTestAnchor(1, "c"))
	windows := []time.Duration{
		60 * time.Second, 120 * time.Second, 240 * time.Second,
		480 * time.Second, 600 * time.Second, 600 * time.Second,
	}
	for strike, window := range windows {
		id := fmt.Sprintf("strike-%d", strike+1)
		mismatch := fenceTestLookup(t, r, provider, capability, id, plan, strings.Repeat("d", 64), uint64(strike+1))
		if got := r.ApplyPrefixCacheLookupV2Result(provider.ID, mismatch); got.Reason != CacheReceiptPromptMismatch {
			t.Fatalf("%s decision=%+v", id, got)
		}
		clock.Advance(window - time.Second)
		if reason := fenceTestCapabilityReason(r, provider); reason != CacheReceiptCapabilityFenced {
			t.Fatalf("%s: capability lifted before %s: %s", id, window, reason)
		}
		clock.Advance(time.Second)
		if reason := fenceTestCapabilityReason(r, provider); reason != CacheReceiptAccepted {
			t.Fatalf("%s: capability still fenced after %s: %s", id, window, reason)
		}
	}
	status := r.CacheRoutingLifecycleStatus()
	if status.FencesApplied != uint64(len(windows)) || status.FencesExpired != uint64(len(windows)) || status.FencedCapabilities != 0 {
		t.Fatalf("lifecycle after escalation = %+v", status)
	}
}

func TestProofFenceAcceptedProofResetsStrikes(t *testing.T) {
	r, provider, capability, clock := fenceTestRegistry(t)
	plan := exactTestPlan(exactTestAnchor(1, "c"))
	valid := plan.Boundaries[0].ChainHash

	first := fenceTestLookup(t, r, provider, capability, "first", plan, strings.Repeat("d", 64), 1)
	if got := r.ApplyPrefixCacheLookupV2Result(provider.ID, first); got.Reason != CacheReceiptPromptMismatch {
		t.Fatalf("first mismatch decision=%+v", got)
	}
	clock.Advance(cacheProofFenceBase)
	accepted := fenceTestLookup(t, r, provider, capability, "accepted", plan, valid, 2)
	if got := r.ApplyPrefixCacheLookupV2Result(provider.ID, accepted); !got.Accepted {
		t.Fatalf("valid proof after first window = %+v", got)
	}

	second := fenceTestLookup(t, r, provider, capability, "second", plan, strings.Repeat("e", 64), 3)
	if got := r.ApplyPrefixCacheLookupV2Result(provider.ID, second); got.Reason != CacheReceiptPromptMismatch {
		t.Fatalf("second mismatch decision=%+v", got)
	}
	clock.Advance(cacheProofFenceBase - time.Second)
	if reason := fenceTestCapabilityReason(r, provider); reason != CacheReceiptCapabilityFenced {
		t.Fatalf("second window lifted early: %s", reason)
	}
	clock.Advance(time.Second)
	if reason := fenceTestCapabilityReason(r, provider); reason != CacheReceiptAccepted {
		t.Fatalf("accepted proof did not reset strikes; window exceeded base: %s", reason)
	}
}

func TestProofFenceFencedReceiptsDoNotExtendWindow(t *testing.T) {
	r, provider, capability, clock := fenceTestRegistry(t)
	plan := exactTestPlan(exactTestAnchor(1, "c"))
	valid := plan.Boundaries[0].ChainHash

	opener := fenceTestLookup(t, r, provider, capability, "opener", plan, strings.Repeat("d", 64), 1)
	if got := r.ApplyPrefixCacheLookupV2Result(provider.ID, opener); got.Reason != CacheReceiptPromptMismatch {
		t.Fatalf("opener decision=%+v", got)
	}
	seq := uint64(1)
	elapsed := time.Duration(0)
	for _, step := range []struct {
		at   time.Duration
		hash string
	}{
		{30 * time.Second, valid},
		{59 * time.Second, strings.Repeat("e", 64)}, // a fenced mismatch is not a new strike
	} {
		clock.Advance(step.at - elapsed)
		elapsed = step.at
		seq++
		fenced := fenceTestLookup(t, r, provider, capability, fmt.Sprintf("fenced-%d", seq), plan, step.hash, seq)
		if got := r.ApplyPrefixCacheLookupV2Result(provider.ID, fenced); got.Reason != CacheReceiptCapabilityFenced {
			t.Fatalf("receipt at +%s = %+v, want fenced", step.at, got)
		}
	}
	clock.Advance(time.Second) // +60 s from the opener
	if reason := fenceTestCapabilityReason(r, provider); reason != CacheReceiptAccepted {
		t.Fatalf("fenced receipts extended the window: %s", reason)
	}
	if status := r.CacheRoutingLifecycleStatus(); status.FencesApplied != 1 || status.FencesExpired != 1 {
		t.Fatalf("lifecycle = %+v, want one window applied and expired", status)
	}
}

func TestProofFenceMismatchDuringActiveWindowKeepsWindow(t *testing.T) {
	tracker := newCacheRoutingTracker(time.Minute, 2)
	capability := testV2Capability("11111111-1111-1111-1111-111111111111")
	now := newFenceTestClock().Now()
	if !tracker.rejectCapability("provider", "model", "ssd", capability, now) {
		t.Fatal("first mismatch did not fence")
	}
	key := cacheV2ProviderModelKey{ProviderID: "provider", ModelID: "model", Tier: "ssd"}
	tracker.mu.Lock()
	until := tracker.rejectedV2[key].until
	tracker.mu.Unlock()
	// Two receipts that both passed the fence check before the window opened.
	if !tracker.rejectCapability("provider", "model", "ssd", capability, now.Add(10*time.Second)) {
		t.Fatal("racing mismatch reported the capability as unfenced")
	}
	tracker.mu.Lock()
	fence := tracker.rejectedV2[key]
	applied := tracker.fencesApplied
	tracker.mu.Unlock()
	if !fence.until.Equal(until) || fence.strikes != 1 || applied != 1 {
		t.Fatalf("racing mismatch changed the window: fence=%+v applied=%d", fence, applied)
	}
}

// A window that lifted by time is charged to fences_expired exactly once, no
// matter which path first notices: a later mismatch on the stale record, a
// capability change, a provider disconnect, or the retention sweep.
func TestProofFenceLapseCountedOnceAcrossForgetPaths(t *testing.T) {
	capability := testV2Capability("11111111-1111-1111-1111-111111111111")
	rotated := capability
	rotated.CacheEpoch = "22222222-2222-2222-2222-222222222222"
	base := newFenceTestClock().Now()
	for name, forget := range map[string]func(*cacheRoutingTracker){
		"stale record overwritten by a fresh mismatch": func(tracker *cacheRoutingTracker) {
			at := base.Add(cacheProofFenceBase + cacheProofFenceRetention)
			tracker.rejectCapability("provider", "model", "ssd", capability, at)
			tracker.capabilityRejected("provider", "model", "ssd", capability, at)
		},
		"capability change": func(tracker *cacheRoutingTracker) {
			tracker.capabilityRejected("provider", "model", "ssd", rotated, base.Add(cacheProofFenceBase))
		},
		"provider disconnect": func(tracker *cacheRoutingTracker) {
			later := func() time.Time { return base.Add(cacheProofFenceBase) }
			tracker.clock.Store(&later)
			tracker.disconnect("provider", cacheHolderRemovalDisconnect)
		},
		"retention sweep": func(tracker *cacheRoutingTracker) {
			tracker.mu.Lock()
			tracker.sweepLocked(base.Add(cacheProofFenceBase + cacheProofFenceRetention))
			tracker.sweepLocked(base.Add(cacheProofFenceBase + cacheProofFenceRetention + time.Hour))
			tracker.mu.Unlock()
		},
	} {
		t.Run(name, func(t *testing.T) {
			tracker := newCacheRoutingTracker(time.Minute, 2)
			if !tracker.rejectCapability("provider", "model", "ssd", capability, base) {
				t.Fatal("mismatch did not fence")
			}
			forget(tracker)
			tracker.mu.Lock()
			expired := tracker.fencesExpired
			tracker.mu.Unlock()
			if expired != 1 {
				t.Fatalf("fences_expired = %d, want exactly 1", expired)
			}
		})
	}
}

func TestProofMismatchDropsOnlyMismatchedBoundaries(t *testing.T) {
	r, provider, capability, clock := fenceTestRegistry(t)
	planA := boundTestCachePlan(r, exactTestPlan(exactTestAnchor(1, "c"), exactTestAnchor(2, "d")))
	planB := boundTestCachePlan(r, exactTestPlan(exactTestAnchor(1, "e"), exactTestAnchor(2, "f")))
	_, readyA := checkpointTestAttempt(t, r, provider, capability, "donor-a", planA, 1)
	if !r.ApplyPrefixCacheReadyV2(provider.ID, readyA) {
		t.Fatal("donation for plan A rejected")
	}
	_, readyB := checkpointTestAttempt(t, r, provider, capability, "donor-b", planB, 3)
	if !r.ApplyPrefixCacheReadyV2(provider.ID, readyB) {
		t.Fatal("donation for plan B rejected")
	}
	if r.cacheRouting.holderCount != 2 {
		t.Fatalf("holders before mismatch = %d, want 2", r.cacheRouting.holderCount)
	}

	mismatch := fenceTestLookup(t, r, provider, capability, "mismatch-a", planA, strings.Repeat("9", 64), 5)
	if got := r.ApplyPrefixCacheLookupV2Result(provider.ID, mismatch); got.Reason != CacheReceiptPromptMismatch {
		t.Fatalf("mismatch decision=%+v", got)
	}
	status := r.CacheRoutingLifecycleStatus()
	if status.HolderRemoved[string(cacheHolderRemovalProofMismatch)] != 1 || r.cacheRouting.holderCount != 1 {
		t.Fatalf("mismatch on plan A removed %d holders (count=%d), want only A's",
			status.HolderRemoved[string(cacheHolderRemovalProofMismatch)], r.cacheRouting.holderCount)
	}
	if hints := memoryTestHints(r, planB, clock.Now()); len(hints) != 0 {
		t.Fatalf("fenced provider still advertised plan B: %+v", hints)
	}

	clock.Advance(cacheProofFenceBase)
	hints := memoryTestHints(r, planB, clock.Now())
	hint, ok := hints[provider.ID]
	if !ok || hint.CachedTokens != planB.Boundaries[1].TokenCount {
		t.Fatalf("plan B holder not routable after the fence lifted: %+v present=%t", hint, ok)
	}
	if hints := memoryTestHints(r, planA, clock.Now()); len(hints) != 0 {
		t.Fatalf("mismatched plan A holder survived: %+v", hints)
	}
	// The replay watermark survives a same-capability mismatch.
	replay := fenceTestLookup(t, r, provider, capability, "replay", planB, planB.Boundaries[1].ChainHash, 2)
	if got := r.ApplyPrefixCacheLookupV2Result(provider.ID, replay); got.Reason != CacheReceiptSequence {
		t.Fatalf("stale sequence after mismatch = %+v, want %s", got, CacheReceiptSequence)
	}
}

func TestProofMismatchDropsBothTiersAtMismatchedBoundaries(t *testing.T) {
	r, provider, capability, _ := fenceTestRegistry(t)
	provider.mu.Lock()
	provider.PrefixCacheMemoryModels = map[string]protocol.PrefixCacheV2Capability{"model": capability}
	provider.mu.Unlock()
	plan := boundTestCachePlan(r, exactTestPlan(exactTestAnchor(16, "c")))
	prompt := plan.Boundaries[0]
	for seq, tier := range []string{"ssd", "memory"} {
		pr := &PendingRequest{RequestID: "donor-" + tier, Model: "model", CachePlan: plan}
		if err := prepareBoundTestCacheAttempt(r, pr, provider); err != nil {
			t.Fatal(err)
		}
		nonce := preparedTestCacheMetadata(pr).CacheReceiptNonce
		lookup := testV2Lookup(nonce, capability, prompt, uint64(2*seq+1))
		lookup.RequestID, lookup.Tier = pr.RequestID, tier
		if got := r.ApplyPrefixCacheLookupV2Result(provider.ID, lookup); !got.Accepted {
			t.Fatalf("%s lookup = %+v", tier, got)
		}
		ready := testV2Ready(nonce, capability, prompt, uint64(2*seq+2))
		ready.RequestID, ready.Tier = pr.RequestID, tier
		if got := r.ApplyPrefixCacheReadyV2Result(provider.ID, ready); !got.Accepted {
			t.Fatalf("%s ready = %+v", tier, got)
		}
	}
	if r.cacheRouting.holderCount != 2 {
		t.Fatalf("holders before mismatch = %d, want ssd + memory", r.cacheRouting.holderCount)
	}
	mismatch := fenceTestLookup(t, r, provider, capability, "mismatch", plan, strings.Repeat("d", 64), 5)
	if got := r.ApplyPrefixCacheLookupV2Result(provider.ID, mismatch); got.Reason != CacheReceiptPromptMismatch {
		t.Fatalf("mismatch decision=%+v", got)
	}
	if r.cacheRouting.holderCount != 0 {
		t.Fatalf("ssd mismatch left %d holders; both tiers share the divergent prompt", r.cacheRouting.holderCount)
	}
	if reason := fenceTestCapabilityReason(r, provider); reason != CacheReceiptCapabilityFenced {
		t.Fatalf("ssd capability = %s, want fenced", reason)
	}
	if _, reason := r.currentPrefixCacheV2CapabilityResult(provider.ID, "model", "memory"); reason != CacheReceiptAccepted {
		t.Fatalf("memory capability = %s; only the receipt's tier is fenced", reason)
	}
}

func TestProofIdentityMismatchDropsWholeProviderModel(t *testing.T) {
	r, provider, capability, _ := fenceTestRegistry(t)
	planA := boundTestCachePlan(r, exactTestPlan(exactTestAnchor(1, "c")))
	planB := boundTestCachePlan(r, exactTestPlan(exactTestAnchor(1, "e")))
	for i, plan := range []CachePlan{planA, planB} {
		_, ready := checkpointTestAttempt(t, r, provider, capability, fmt.Sprintf("donor-%d", i), plan, uint64(2*i+1))
		if !r.ApplyPrefixCacheReadyV2(provider.ID, ready) {
			t.Fatalf("donation %d rejected", i)
		}
	}
	identity := fenceTestLookup(t, r, provider, capability, "identity", planA, planA.Boundaries[0].ChainHash, 5)
	identity.CacheEpoch = "22222222-2222-2222-2222-222222222222"
	if got := r.ApplyPrefixCacheLookupV2Result(provider.ID, identity); got.Reason != CacheReceiptIdentityMismatch {
		t.Fatalf("identity decision=%+v", got)
	}
	status := r.CacheRoutingLifecycleStatus()
	if status.HolderRemoved[string(cacheHolderRemovalProofMismatch)] != 2 || r.cacheRouting.holderCount != 0 {
		t.Fatalf("identity mismatch kept stale-identity holders: removed=%d count=%d",
			status.HolderRemoved[string(cacheHolderRemovalProofMismatch)], r.cacheRouting.holderCount)
	}
}

func TestProofFenceCapabilityChangeClearsAndResetsStrikes(t *testing.T) {
	r, provider, capability, clock := fenceTestRegistry(t)
	plan := exactTestPlan(exactTestAnchor(1, "c"))
	for strike := 1; strike <= 2; strike++ {
		mismatch := fenceTestLookup(t, r, provider, capability, fmt.Sprintf("strike-%d", strike), plan, strings.Repeat("d", 64), uint64(strike))
		if got := r.ApplyPrefixCacheLookupV2Result(provider.ID, mismatch); got.Reason != CacheReceiptPromptMismatch {
			t.Fatalf("strike %d decision=%+v", strike, got)
		}
		clock.Advance(cacheProofFenceDuration(uint32(strike)))
	}
	third := fenceTestLookup(t, r, provider, capability, "strike-3", plan, strings.Repeat("d", 64), 3)
	if got := r.ApplyPrefixCacheLookupV2Result(provider.ID, third); got.Reason != CacheReceiptPromptMismatch {
		t.Fatalf("third decision=%+v", got)
	}
	rotated := capability
	rotated.CacheEpoch = "22222222-2222-2222-2222-222222222222"
	provider.mu.Lock()
	provider.Models = []protocol.ModelInfo{{ID: "model", WeightHash: capability.ModelAggregateHash}}
	r.modelIndex.sync(provider)
	provider.mu.Unlock()
	if err := r.UpdatePrefixCacheCapabilities(provider.ID, 2, []protocol.PrefixCacheV2Capability{rotated}); err != nil {
		t.Fatal(err)
	}
	if reason := fenceTestCapabilityReason(r, provider); reason != CacheReceiptAccepted {
		t.Fatalf("capability change did not clear the fence: %s", reason)
	}
	if status := r.CacheRoutingLifecycleStatus(); status.FencedCapabilities != 0 {
		t.Fatalf("cleared fence still counted: %+v", status)
	}
	fresh := fenceTestLookup(t, r, provider, rotated, "fresh", plan, strings.Repeat("d", 64), 1)
	if got := r.ApplyPrefixCacheLookupV2Result(provider.ID, fresh); got.Reason != CacheReceiptPromptMismatch {
		t.Fatalf("fresh decision=%+v", got)
	}
	clock.Advance(cacheProofFenceBase)
	if reason := fenceTestCapabilityReason(r, provider); reason != CacheReceiptAccepted {
		t.Fatalf("new capability inherited old strikes: %s", reason)
	}
}

func TestProofFenceSweepDropsStaleRecords(t *testing.T) {
	r, provider, capability, clock := fenceTestRegistry(t)
	plan := exactTestPlan(exactTestAnchor(1, "c"))
	mismatch := fenceTestLookup(t, r, provider, capability, "mismatch", plan, strings.Repeat("d", 64), 1)
	if got := r.ApplyPrefixCacheLookupV2Result(provider.ID, mismatch); got.Reason != CacheReceiptPromptMismatch {
		t.Fatalf("decision=%+v", got)
	}
	tracker := r.cacheRouting
	records := func() int {
		tracker.mu.Lock()
		defer tracker.mu.Unlock()
		return len(tracker.rejectedV2)
	}
	clock.Advance(cacheProofFenceBase + cacheProofFenceRetention - time.Second)
	tracker.mu.Lock()
	tracker.sweepLocked(clock.Now())
	tracker.mu.Unlock()
	if records() != 1 {
		t.Fatal("sweep dropped strike memory inside the retention")
	}
	clock.Advance(time.Second)
	tracker.mu.Lock()
	tracker.sweepLocked(clock.Now())
	tracker.mu.Unlock()
	if records() != 0 {
		t.Fatal("sweep retained a fence record past the retention")
	}
	if status := r.CacheRoutingLifecycleStatus(); status.FencesApplied != 1 || status.FencesExpired != 1 || status.FencedCapabilities != 0 {
		t.Fatalf("lifecycle after sweep = %+v", status)
	}
	// A mismatch after the retention starts over at the base window.
	again := fenceTestLookup(t, r, provider, capability, "again", plan, strings.Repeat("d", 64), 2)
	if got := r.ApplyPrefixCacheLookupV2Result(provider.ID, again); got.Reason != CacheReceiptPromptMismatch {
		t.Fatalf("decision=%+v", got)
	}
	clock.Advance(cacheProofFenceBase)
	if reason := fenceTestCapabilityReason(r, provider); reason != CacheReceiptAccepted {
		t.Fatalf("stale strike memory escalated a fresh fence: %s", reason)
	}
}
