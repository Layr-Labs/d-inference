package registry_test

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheindex"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheplan"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachetracker"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestProofFenceExpiresAndAcceptsLaterProof(t *testing.T) {
	r, provider, capability, clock := fenceTestRegistry(t)
	plan := exactTestPlan(exactTestAnchor(1, "c"))
	valid := plan.Boundaries[0].ChainHash
	seq := uint64(0)
	next := func() uint64 { seq++; return seq }

	mismatch := fenceTestLookup(t, r, provider, capability, "mismatch", plan, strings.Repeat("d", 64), next())
	if got := r.ApplyPrefixCacheLookupV2Result(provider.ID, mismatch); got.Accepted || got.Reason != production.CacheReceiptPromptMismatch {
		t.Fatalf("mismatch decision=%+v", got)
	}
	if reason := fenceTestCapabilityReason(r, provider); reason != production.CacheReceiptCapabilityFenced {
		t.Fatalf("capability after mismatch = %s, want fenced", reason)
	}
	if status := r.CacheRoutingLifecycleStatus(); status.FencesApplied != 1 || status.FencesExpired != 0 || status.FencedCapabilities != 1 {
		t.Fatalf("lifecycle after mismatch = %+v", status)
	}

	clock.Advance(cachetracker.ProofFenceBase - time.Second)
	early := fenceTestLookup(t, r, provider, capability, "early", plan, valid, next())
	if got := r.ApplyPrefixCacheLookupV2Result(provider.ID, early); got.Accepted || got.Reason != production.CacheReceiptCapabilityFenced {
		t.Fatalf("receipt one second before expiry = %+v, want fenced", got)
	}

	clock.Advance(time.Second)
	if reason := fenceTestCapabilityReason(r, provider); reason != production.CacheReceiptAccepted {
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

	remaining := r.fences.Len()

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
		if got := r.ApplyPrefixCacheLookupV2Result(provider.ID, mismatch); got.Reason != production.CacheReceiptPromptMismatch {
			t.Fatalf("%s decision=%+v", id, got)
		}
		clock.Advance(window - time.Second)
		if reason := fenceTestCapabilityReason(r, provider); reason != production.CacheReceiptCapabilityFenced {
			t.Fatalf("%s: capability lifted before %s: %s", id, window, reason)
		}
		clock.Advance(time.Second)
		if reason := fenceTestCapabilityReason(r, provider); reason != production.CacheReceiptAccepted {
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
	if got := r.ApplyPrefixCacheLookupV2Result(provider.ID, first); got.Reason != production.CacheReceiptPromptMismatch {
		t.Fatalf("first mismatch decision=%+v", got)
	}
	clock.Advance(cachetracker.ProofFenceBase)
	accepted := fenceTestLookup(t, r, provider, capability, "accepted", plan, valid, 2)
	if got := r.ApplyPrefixCacheLookupV2Result(provider.ID, accepted); !got.Accepted {
		t.Fatalf("valid proof after first window = %+v", got)
	}

	second := fenceTestLookup(t, r, provider, capability, "second", plan, strings.Repeat("e", 64), 3)
	if got := r.ApplyPrefixCacheLookupV2Result(provider.ID, second); got.Reason != production.CacheReceiptPromptMismatch {
		t.Fatalf("second mismatch decision=%+v", got)
	}
	clock.Advance(cachetracker.ProofFenceBase - time.Second)
	if reason := fenceTestCapabilityReason(r, provider); reason != production.CacheReceiptCapabilityFenced {
		t.Fatalf("second window lifted early: %s", reason)
	}
	clock.Advance(time.Second)
	if reason := fenceTestCapabilityReason(r, provider); reason != production.CacheReceiptAccepted {
		t.Fatalf("accepted proof did not reset strikes; window exceeded base: %s", reason)
	}
}

func TestProofFenceFencedReceiptsDoNotExtendWindow(t *testing.T) {
	r, provider, capability, clock := fenceTestRegistry(t)
	plan := exactTestPlan(exactTestAnchor(1, "c"))
	valid := plan.Boundaries[0].ChainHash

	opener := fenceTestLookup(t, r, provider, capability, "opener", plan, strings.Repeat("d", 64), 1)
	if got := r.ApplyPrefixCacheLookupV2Result(provider.ID, opener); got.Reason != production.CacheReceiptPromptMismatch {
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
		if got := r.ApplyPrefixCacheLookupV2Result(provider.ID, fenced); got.Reason != production.CacheReceiptCapabilityFenced {
			t.Fatalf("receipt at +%s = %+v, want fenced", step.at, got)
		}
	}
	clock.Advance(time.Second) // +60 s from the opener
	if reason := fenceTestCapabilityReason(r, provider); reason != production.CacheReceiptAccepted {
		t.Fatalf("fenced receipts extended the window: %s", reason)
	}
	if status := r.CacheRoutingLifecycleStatus(); status.FencesApplied != 1 || status.FencesExpired != 1 {
		t.Fatalf("lifecycle = %+v, want one window applied and expired", status)
	}
}

func TestProofFenceMismatchDuringActiveWindowKeepsWindow(t *testing.T) {
	records := cacheindex.NewRecords[cachetracker.FenceKey, cachetracker.FenceRecord]()
	tracker := cachetracker.NewProofs(&cacheplan.Generation{}, records)
	capability := testV2Capability("11111111-1111-1111-1111-111111111111")
	now := newFenceTestClock().Now()
	if !tracker.Reject("provider", "model", "ssd", capability, now) {
		t.Fatal("first mismatch did not fence")
	}
	key := cachetracker.FenceKey{ProviderID: "provider", ModelID: "model", Tier: "ssd"}

	until := records.Lookup(key).Until

	// Two receipts that both passed the fence check before the window opened.
	if !tracker.Reject("provider", "model", "ssd", capability, now.Add(10*time.Second)) {
		t.Fatal("racing mismatch reported the capability as unfenced")
	}

	fence := records.Lookup(key)
	applied, _ := tracker.Counts()

	if !fence.Until.Equal(until) || fence.Strikes != 1 || applied != 1 {
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
	key := cachetracker.FenceKey{ProviderID: "provider", ModelID: "model", Tier: "ssd"}
	for name, forget := range map[string]func(*cachetracker.Proofs){
		"stale record overwritten by a fresh mismatch": func(tracker *cachetracker.Proofs) {
			at := base.Add(cachetracker.ProofFenceBase + cachetracker.ProofFenceRetention)
			tracker.Reject("provider", "model", "ssd", capability, at)
			tracker.Rejected(key, capability, at)
		},
		"capability change": func(tracker *cachetracker.Proofs) {
			tracker.Rejected(key, rotated, base.Add(cachetracker.ProofFenceBase))
		},
		"provider disconnect": func(tracker *cachetracker.Proofs) {
			tracker.ForgetProvider("provider", base.Add(cachetracker.ProofFenceBase))
		},
		"retention sweep": func(tracker *cachetracker.Proofs) {
			tracker.Sweep(base.Add(cachetracker.ProofFenceBase + cachetracker.ProofFenceRetention))
			tracker.Sweep(base.Add(cachetracker.ProofFenceBase + cachetracker.ProofFenceRetention + time.Hour))
		},
	} {
		t.Run(name, func(t *testing.T) {
			records := cacheindex.NewRecords[cachetracker.FenceKey, cachetracker.FenceRecord]()
			tracker := cachetracker.NewProofs(&cacheplan.Generation{}, records)
			if !tracker.Reject("provider", "model", "ssd", capability, base) {
				t.Fatal("mismatch did not fence")
			}
			forget(tracker)
			_, expired := tracker.Counts()
			if expired != 1 {
				t.Fatalf("fences_expired = %d, want exactly 1", expired)
			}
		})
	}
}

// The retention sweep is reached through the paths production actually
// exercises: a status scrape, the bounded state counts, and a receipt from
// an unrelated provider (its decision runs the due sweep).
func TestProofFenceSweepThroughNaturalEntries(t *testing.T) {
	for name, trigger := range map[string]func(*testing.T, *fenceRegistry, protocol.PrefixCacheV2Capability, *fenceTestClock){
		"lifecycle status": func(_ *testing.T, r *fenceRegistry, _ protocol.PrefixCacheV2Capability, _ *fenceTestClock) {
			r.CacheRoutingLifecycleStatus()
		},
		"state counts": func(_ *testing.T, r *fenceRegistry, _ protocol.PrefixCacheV2Capability, _ *fenceTestClock) {
			r.CacheRoutingStateCounts()
		},
		"receipt from another provider": func(t *testing.T, r *fenceRegistry, capability protocol.PrefixCacheV2Capability, _ *fenceTestClock) {
			other := checkpointTestProvider(t, r, "machine-b", capability)
			plan := exactTestPlan(exactTestAnchor(1, "c"))
			lookup := fenceTestLookup(t, r, other, capability, "other", plan, plan.Boundaries[0].ChainHash, 1)
			if got := r.ApplyPrefixCacheLookupV2Result(other.ID, lookup); !got.Accepted {
				t.Fatalf("unrelated provider's proof = %+v", got)
			}
		},
	} {
		t.Run(name, func(t *testing.T) {
			r, provider, capability, clock := fenceTestRegistry(t)
			plan := exactTestPlan(exactTestAnchor(1, "c"))
			mismatch := fenceTestLookup(t, r, provider, capability, "mismatch", plan, strings.Repeat("d", 64), 1)
			if got := r.ApplyPrefixCacheLookupV2Result(provider.ID, mismatch); got.Reason != production.CacheReceiptPromptMismatch {
				t.Fatalf("decision=%+v", got)
			}
			clock.Advance(cachetracker.ProofFenceBase + cachetracker.ProofFenceRetention)
			trigger(t, r, capability, clock)
			tracker := r

			records := tracker.fences.Len()
			_, expired := tracker.proofs.Counts()

			if records != 0 || expired != 1 {
				t.Fatalf("after %s: records=%d fences_expired=%d, want 0 and 1", name, records, expired)
			}
		})
	}
}

func TestProofMismatchDropsOnlyMismatchedBoundaries(t *testing.T) {
	r, provider, capability, clock := fenceTestRegistry(t)
	planA := r.plans.bind(exactTestPlan(exactTestAnchor(1, "c"), exactTestAnchor(2, "d")))
	planB := r.plans.bind(exactTestPlan(exactTestAnchor(1, "e"), exactTestAnchor(2, "f")))
	_, readyA := fenceTestCheckpoint(t, r, provider, capability, "donor-a", planA, 1)
	if !r.ApplyPrefixCacheReadyV2(provider.ID, readyA) {
		t.Fatal("donation for plan A rejected")
	}
	_, readyB := fenceTestCheckpoint(t, r, provider, capability, "donor-b", planB, 3)
	if !r.ApplyPrefixCacheReadyV2(provider.ID, readyB) {
		t.Fatal("donation for plan B rejected")
	}
	if r.holders.Len() != 2 {
		t.Fatalf("holders before mismatch = %d, want 2", r.holders.Len())
	}

	mismatch := fenceTestLookup(t, r, provider, capability, "mismatch-a", planA, strings.Repeat("9", 64), 5)
	if got := r.ApplyPrefixCacheLookupV2Result(provider.ID, mismatch); got.Reason != production.CacheReceiptPromptMismatch {
		t.Fatalf("mismatch decision=%+v", got)
	}
	status := r.CacheRoutingLifecycleStatus()
	if status.HolderRemoved["proof_mismatch"] != 1 || r.holders.Len() != 1 {
		t.Fatalf("mismatch on plan A removed %d holders (count=%d), want only A's",
			status.HolderRemoved["proof_mismatch"], r.holders.Len())
	}
	if hints := fenceTestHints(r, planB, clock.Now()); len(hints) != 0 {
		t.Fatalf("fenced provider still advertised plan B: %+v", hints)
	}

	clock.Advance(cachetracker.ProofFenceBase)
	hints := fenceTestHints(r, planB, clock.Now())
	hint, ok := hints[provider.ID]
	if !ok || hint.CachedTokens != planB.Boundaries[1].TokenCount {
		t.Fatalf("plan B holder not routable after the fence lifted: %+v present=%t", hint, ok)
	}
	if hints := fenceTestHints(r, planA, clock.Now()); len(hints) != 0 {
		t.Fatalf("mismatched plan A holder survived: %+v", hints)
	}
	// The replay watermark survives a same-capability mismatch.
	replay := fenceTestLookup(t, r, provider, capability, "replay", planB, planB.Boundaries[1].ChainHash, 2)
	if got := r.ApplyPrefixCacheLookupV2Result(provider.ID, replay); got.Reason != production.CacheReceiptSequence {
		t.Fatalf("stale sequence after mismatch = %+v, want %s", got, production.CacheReceiptSequence)
	}
}

func TestProofMismatchDropsBothTiersAtMismatchedBoundaries(t *testing.T) {
	r, provider, capability, _ := fenceTestRegistry(t)
	provider.Mu().Lock()
	provider.PrefixCacheMemoryModels = map[string]protocol.PrefixCacheV2Capability{"model": capability}
	provider.Mu().Unlock()
	plan := r.plans.bind(exactTestPlan(exactTestAnchor(16, "c")))
	prompt := plan.Boundaries[0]
	for seq, tier := range []string{"ssd", "memory"} {
		pr := &production.PendingRequest{RequestID: "donor-" + tier, Model: "model", CachePlan: plan}
		if err := r.PrepareCacheAttempt(pr, provider); err != nil {
			t.Fatal(err)
		}
		nonce := pr.CacheAttemptSnapshot().MetadataMessage().CacheReceiptNonce
		lookup := fenceTestV2Lookup(nonce, capability, prompt, uint64(2*seq+1))
		lookup.RequestID, lookup.Tier = pr.RequestID, tier
		if got := r.ApplyPrefixCacheLookupV2Result(provider.ID, lookup); !got.Accepted {
			t.Fatalf("%s lookup = %+v", tier, got)
		}
		ready := fenceTestV2Ready(nonce, capability, prompt, uint64(2*seq+2))
		ready.RequestID, ready.Tier = pr.RequestID, tier
		if got := r.ApplyPrefixCacheReadyV2Result(provider.ID, ready); !got.Accepted {
			t.Fatalf("%s ready = %+v", tier, got)
		}
	}
	if r.holders.Len() != 2 {
		t.Fatalf("holders before mismatch = %d, want ssd + memory", r.holders.Len())
	}
	mismatch := fenceTestLookup(t, r, provider, capability, "mismatch", plan, strings.Repeat("d", 64), 5)
	if got := r.ApplyPrefixCacheLookupV2Result(provider.ID, mismatch); got.Reason != production.CacheReceiptPromptMismatch {
		t.Fatalf("mismatch decision=%+v", got)
	}
	if r.holders.Len() != 0 {
		t.Fatalf("ssd mismatch left %d holders; both tiers share the divergent prompt", r.holders.Len())
	}
	if reason := fenceTestCapabilityReason(r, provider); reason != production.CacheReceiptCapabilityFenced {
		t.Fatalf("ssd capability = %s, want fenced", reason)
	}
	if _, reason := r.admission.Admit(provider.ID, "model", "memory"); reason != production.CacheReceiptAccepted {
		t.Fatalf("memory capability = %s; only the receipt's tier is fenced", reason)
	}
}

func TestProofIdentityMismatchDropsWholeProviderModel(t *testing.T) {
	r, provider, capability, _ := fenceTestRegistry(t)
	planA := r.plans.bind(exactTestPlan(exactTestAnchor(1, "c")))
	planB := r.plans.bind(exactTestPlan(exactTestAnchor(1, "e")))
	for i, plan := range []production.CachePlan{planA, planB} {
		_, ready := fenceTestCheckpoint(t, r, provider, capability, fmt.Sprintf("donor-%d", i), plan, uint64(2*i+1))
		if !r.ApplyPrefixCacheReadyV2(provider.ID, ready) {
			t.Fatalf("donation %d rejected", i)
		}
	}
	identity := fenceTestLookup(t, r, provider, capability, "identity", planA, planA.Boundaries[0].ChainHash, 5)
	identity.CacheEpoch = "22222222-2222-2222-2222-222222222222"
	if got := r.ApplyPrefixCacheLookupV2Result(provider.ID, identity); got.Reason != production.CacheReceiptIdentityMismatch {
		t.Fatalf("identity decision=%+v", got)
	}
	status := r.CacheRoutingLifecycleStatus()
	if status.HolderRemoved["proof_mismatch"] != 2 || r.holders.Len() != 0 {
		t.Fatalf("identity mismatch kept stale-identity holders: removed=%d count=%d",
			status.HolderRemoved["proof_mismatch"], r.holders.Len())
	}
}

func TestProofFenceCapabilityChangeClearsAndResetsStrikes(t *testing.T) {
	r, provider, capability, clock := fenceTestRegistry(t)
	plan := exactTestPlan(exactTestAnchor(1, "c"))
	for strike := 1; strike <= 2; strike++ {
		mismatch := fenceTestLookup(t, r, provider, capability, fmt.Sprintf("strike-%d", strike), plan, strings.Repeat("d", 64), uint64(strike))
		if got := r.ApplyPrefixCacheLookupV2Result(provider.ID, mismatch); got.Reason != production.CacheReceiptPromptMismatch {
			t.Fatalf("strike %d decision=%+v", strike, got)
		}
		clock.Advance(cachetracker.ProofFenceDuration(uint32(strike)))
	}
	third := fenceTestLookup(t, r, provider, capability, "strike-3", plan, strings.Repeat("d", 64), 3)
	if got := r.ApplyPrefixCacheLookupV2Result(provider.ID, third); got.Reason != production.CacheReceiptPromptMismatch {
		t.Fatalf("third decision=%+v", got)
	}
	rotated := capability
	rotated.CacheEpoch = "22222222-2222-2222-2222-222222222222"
	merged, dropped := r.MergeProviderModels(provider.ID, []protocol.ModelInfo{{ID: "model", WeightHash: capability.ModelAggregateHash}})
	if len(merged) != 1 || merged[0] != "model" || len(dropped) != 0 {
		t.Fatalf("model inventory not installed: merged=%v dropped=%v", merged, dropped)
	}
	if err := r.UpdatePrefixCacheCapabilities(provider.ID, 2, []protocol.PrefixCacheV2Capability{rotated}); err != nil {
		t.Fatal(err)
	}
	// The heartbeat itself lifts the fence: a status scrape before any query
	// of the replaced capability must not count the dead record.
	if status := r.CacheRoutingLifecycleStatus(); status.FencedCapabilities != 0 {
		t.Fatalf("replaced capability still counted as fenced before any query: %+v", status)
	}
	records := r.fences.Len()
	if records != 0 {
		t.Fatal("capability change retained the fence record")
	}
	if reason := fenceTestCapabilityReason(r, provider); reason != production.CacheReceiptAccepted {
		t.Fatalf("capability change did not clear the fence: %s", reason)
	}
	fresh := fenceTestLookup(t, r, provider, rotated, "fresh", plan, strings.Repeat("d", 64), 1)
	if got := r.ApplyPrefixCacheLookupV2Result(provider.ID, fresh); got.Reason != production.CacheReceiptPromptMismatch {
		t.Fatalf("fresh decision=%+v", got)
	}
	clock.Advance(cachetracker.ProofFenceBase)
	if reason := fenceTestCapabilityReason(r, provider); reason != production.CacheReceiptAccepted {
		t.Fatalf("new capability inherited old strikes: %s", reason)
	}
}

func TestProofFenceSweepDropsStaleRecords(t *testing.T) {
	r, provider, capability, clock := fenceTestRegistry(t)
	plan := exactTestPlan(exactTestAnchor(1, "c"))
	mismatch := fenceTestLookup(t, r, provider, capability, "mismatch", plan, strings.Repeat("d", 64), 1)
	if got := r.ApplyPrefixCacheLookupV2Result(provider.ID, mismatch); got.Reason != production.CacheReceiptPromptMismatch {
		t.Fatalf("decision=%+v", got)
	}
	tracker := r
	records := func() int {

		return tracker.fences.Len()
	}
	clock.Advance(cachetracker.ProofFenceBase + cachetracker.ProofFenceRetention - time.Second)

	tracker.CacheRoutingLifecycleStatus()

	if records() != 1 {
		t.Fatal("sweep dropped strike memory inside the retention")
	}
	clock.Advance(time.Second)

	tracker.CacheRoutingLifecycleStatus()

	if records() != 0 {
		t.Fatal("sweep retained a fence record past the retention")
	}
	if status := r.CacheRoutingLifecycleStatus(); status.FencesApplied != 1 || status.FencesExpired != 1 || status.FencedCapabilities != 0 {
		t.Fatalf("lifecycle after sweep = %+v", status)
	}
	// A mismatch after the retention starts over at the base window.
	again := fenceTestLookup(t, r, provider, capability, "again", plan, strings.Repeat("d", 64), 2)
	if got := r.ApplyPrefixCacheLookupV2Result(provider.ID, again); got.Reason != production.CacheReceiptPromptMismatch {
		t.Fatalf("decision=%+v", got)
	}
	clock.Advance(cachetracker.ProofFenceBase)
	if reason := fenceTestCapabilityReason(r, provider); reason != production.CacheReceiptAccepted {
		t.Fatalf("stale strike memory escalated a fresh fence: %s", reason)
	}
}
