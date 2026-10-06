package registry_test

import (
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheactivation"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheplan"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachetracker"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

type holderIndexCleanupBarrier struct {
	production.CacheMaintainer
	providerID      string
	reached, resume chan struct{}
}

func (b *holderIndexCleanupBarrier) InvalidateProviderEvidence(id string, reason cachetracker.RemovalReason, preserveFences bool) {
	if id == b.providerID {
		close(b.reached)
		<-b.resume
	}
	b.CacheMaintainer.InvalidateProviderEvidence(id, reason, preserveFences)
}

func holderIndexRegistry(t *testing.T, barrier *holderIndexCleanupBarrier) (*fenceRegistry, **cacheIndexKernelFixture, *production.Provider, protocol.PrefixCacheV2Capability) {
	t.Helper()
	r := &fenceRegistry{}
	var tracker *cacheIndexKernelFixture
	deps := production.CacheDependencies{
		Generations: func() *cacheplan.Generation {
			r.plans.generation = &cacheplan.Generation{}
			return r.plans.generation
		},
		Trackers: func(config cachetracker.Config[*production.Provider]) *cachetracker.Tracker[*production.Provider] {
			tracker = &cacheIndexKernelFixture{Tracker: cachetracker.New(config), config: config}
			return tracker.Tracker
		},
		HintQueries: func(query production.CacheHintQuery) production.CacheHintQuerier {
			r.query = query
			return query
		},
		Maintenance: func(owner production.CacheMaintenance) production.CacheMaintainer {
			if barrier == nil {
				return owner
			}
			barrier.CacheMaintainer = owner
			return barrier
		},
	}
	var p *production.Provider
	var capability protocol.PrefixCacheV2Capability
	r.Registry, p, capability = exactTestRegistry(t, production.Dependencies{Cache: deps})
	r.routeKey = cacheactivation.HMACBytes([]byte("0123456789abcdef0123456789abcdef"), []byte("darkbloom/cache-routing/route/v3"))
	return r, &tracker, p, capability
}

func indexTestCapability(index int) protocol.PrefixCacheV2Capability {
	capability := exactTestCapability(fmt.Sprintf("%08x-1111-1111-1111-111111111111", index+1))
	capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
	return capability
}

func TestCacheHolderIndexBoundsIndependentEpochsAndSurvivesChurn(t *testing.T) {
	barrier := &holderIndexCleanupBarrier{providerID: "machine-7", reached: make(chan struct{}), resume: make(chan struct{})}
	r, retained, _, _ := holderIndexRegistry(t, barrier)
	r.Disconnect("provider-a")
	config := r.CacheRoutingConfigSnapshot()
	config.MasterKey = generationTestConfig(production.CacheRoutingOn).MasterKey
	config.MaxHolders = 4
	if err := r.ConfigureCacheRouting(config); err != nil {
		t.Fatal(err)
	}
	anchor := exactTestAnchor(16, "c")
	plan := exactTestPlan(anchor)
	providers := make([]*production.Provider, 8)
	capabilities := make([]protocol.PrefixCacheV2Capability, len(providers))
	var lastReady *protocol.PrefixCacheReadyV2Message
	for i := range providers {
		capabilities[i] = indexTestCapability(i)
		providers[i] = checkpointTestProvider(t, r, fmt.Sprintf("machine-%d", i), capabilities[i])
		_, ready := fenceTestCheckpoint(t, r, providers[i], capabilities[i], fmt.Sprintf("donor-%d", i), plan, 1)
		if !r.ApplyPrefixCacheReadyV2(providers[i].ID, ready) {
			t.Fatalf("machine %d durable receipt rejected", i)
		}
		lastReady = ready
	}
	hints := fenceTestHints(r, plan, time.Now())
	if len(hints) != 4 {
		t.Fatalf("independent epochs bypassed four-machine bound: %d hints", len(hints))
	}
	for i, p := range providers {
		_, present := hints[p.ID]
		if present != (i >= 4) {
			t.Fatalf("oldest-holder eviction: machine %d present=%v", i, present)
		}
	}
	tracker := *retained
	buckets, holders, order := tracker.config.Holders.BucketCount(), tracker.config.Holders.Len(), tracker.config.HolderOrder.Len()
	if buckets != 1 || holders != 4 || order != 4 {
		t.Fatalf("content index not bounded: buckets=%d holders=%d order=%d", buckets, holders, order)
	}

	// A cache epoch change invalidates only that machine's evidence. The other
	// machines retain their independent proof for the same exact content key.
	p := providers[7]
	oldHint := hints[p.ID]
	rotated := indexTestCapability(100)
	if err := r.UpdatePrefixCacheCapabilities(p.ID, 2, []protocol.PrefixCacheV2Capability{rotated}); err != nil {
		t.Fatal(err)
	}
	p.Mu().Lock()
	current := oldHint.CurrentForProviderLocked(p, "model")
	p.Mu().Unlock()
	if current || r.ApplyPrefixCacheReadyV2(p.ID, lastReady) {
		t.Fatal("old epoch survived capability change or replay")
	}
	hints = fenceTestHints(r, plan, time.Now())
	if len(hints) != 3 {
		t.Fatalf("epoch rotation removed another machine: %+v", hints)
	}
	for i := 4; i < 7; i++ {
		if hints[providers[i].ID].Capability.CacheEpoch != capabilities[i].CacheEpoch {
			t.Fatalf("machine %d lost its own epoch", i)
		}
	}
	// Sequence 1 is valid for the new epoch, but only a new request-bound proof
	// may restore the removed machine. No previous holder bucket is resurrected.
	_, newReady := fenceTestCheckpoint(t, r, p, rotated, "after-rotation", plan, 1)
	if !r.ApplyPrefixCacheReadyV2(p.ID, newReady) {
		t.Fatal("new epoch's verified publication rejected")
	}
	hints = fenceTestHints(r, plan, time.Now())
	if len(hints) != 4 || hints[p.ID].Capability.CacheEpoch != rotated.CacheEpoch {
		t.Fatalf("new live epoch did not rejoin exact-content bucket: %+v", hints)
	}
	// Misses are also provider-local even though their lookup key is shared.
	fenceTestCheckpoint(t, r, providers[6], capabilities[6], "missing-file", plan, 3)
	if hints = fenceTestHints(r, plan, time.Now()); len(hints) != 3 || hints[p.ID].Provider != p {
		t.Fatalf("one provider miss invalidated another live holder: %+v", hints)
	}
	// Reusing a provider ID cannot inherit a prior connection's receipt.
	// Pause the real disconnect after directory removal but before cache cleanup,
	// so this assertion still tests stale evidence rather than an empty index.
	disconnected := make(chan struct{})
	var releaseOnce sync.Once
	release := func() { releaseOnce.Do(func() { close(barrier.resume) }) }
	go func() {
		r.Disconnect(p.ID)
		close(disconnected)
	}()
	t.Cleanup(func() { release(); <-disconnected })
	select {
	case <-barrier.reached:
	case <-time.After(5 * time.Second):
		t.Fatal("disconnect did not reach cache cleanup")
	}
	replacement := checkpointTestProvider(t, r, p.ID, rotated)
	if hints = fenceTestHints(r, plan, time.Now()); len(hints) != 2 {
		t.Fatalf("new connection inherited old proof: %+v", hints)
	}
	release()
	<-disconnected
	_, fresh := fenceTestCheckpoint(t, r, replacement, rotated, "new-connection", plan, 3)
	if !r.ApplyPrefixCacheReadyV2(replacement.ID, fresh) {
		t.Fatal("new connection's verified receipt rejected")
	}
	if hint := fenceTestHints(r, plan, time.Now())[p.ID]; hint.Provider != replacement {
		t.Fatalf("replacement did not become live holder: %+v", hint)
	}
}

func TestCacheHolderIndexDoesNotLockUnrelatedProviders(t *testing.T) {
	r, _, holder, capability := holderIndexRegistry(t, nil)
	plan := exactTestPlan(exactTestAnchor(16, "c"))
	_, ready := fenceTestCheckpoint(t, r, holder, capability, "donor", plan, 1)
	if !r.ApplyPrefixCacheReadyV2(holder.ID, ready) {
		t.Fatal("receipt rejected")
	}
	unrelated := checkpointTestProvider(t, r, "busy-unrelated", indexTestCapability(2))
	unrelated.Mu().Lock()
	finished := make(chan map[string]production.CacheRoutingHint, 1)
	go func() { finished <- fenceTestHints(r, plan, time.Now()) }()
	select {
	case hints := <-finished:
		unrelated.Mu().Unlock()
		if len(hints) != 1 || hints[holder.ID].Provider != holder {
			t.Fatalf("exact holder missing: %+v", hints)
		}
	case <-time.After(5 * time.Second):
		unrelated.Mu().Unlock()
		<-finished
		t.Fatal("holder lookup waited for an unrelated provider's lock")
	}
}

func TestCacheHolderIndexScopeAndTierIsolation(t *testing.T) {
	plan := exactTestPlan(exactTestAnchor(16, "c"))
	key := []byte("route-key")
	ssd := cachetracker.CacheTierBoundaryKey(key, plan, plan.Boundaries[0], "ssd")
	if ssd == "" || ssd == cachetracker.CacheTierBoundaryKey(key, plan, plan.Boundaries[0], "memory") {
		t.Fatal("tiers share holder evidence")
	}
	variants := []production.CachePlan{plan, plan, plan, plan}
	variants[0].CacheScope = "another-tenant"
	variants[1].ModelAggregateHash = "another-artifact"
	variants[2].PromptContractID = "another-contract"
	variants[3].Boundaries = []protocol.PrefixCacheAnchor{exactTestAnchor(16, "d")}
	for i, variant := range variants {
		if ssd == cachetracker.CacheTierBoundaryKey(key, variant, variant.Boundaries[0], "ssd") {
			t.Fatalf("variant %d crossed content isolation", i)
		}
	}
	if cachetracker.CacheTierBoundaryKey(key, plan, plan.Boundaries[0], "unknown") != "" {
		t.Fatal("unknown tier entered the index")
	}
}

func TestCacheHolderIndexRetainsLongestCurrentEndpoint(t *testing.T) {
	_, p, capability := exactTestRegistry(t)
	short, long := exactTestAnchor(1, "c"), exactTestAnchor(2, "d")
	plan := exactTestPlan(short, long)
	holder := indexKernelHolder{ProviderID: p.ID, Provider: p, ModelID: "model",
		CacheEpoch: capability.CacheEpoch, Anchor: short, StageMs: 1}
	longer := holder
	longer.Anchor, longer.StageMs = long, 5000
	caps := map[string]production.CacheRoutingCapability{p.ID: {Provider: p, Capability: capability}}
	matches := []cachetracker.Match[*production.Provider]{{Holder: longer, Tier: "ssd"}, {Holder: holder, Tier: "ssd"}}
	if hint := production.CacheHintsForMatches(plan, matches, caps)[p.ID]; hint.CachedTokens != long.TokenCount || hint.StageMs != 5000 {
		t.Fatalf("a cheaper short record overrode the provider's longest selector: %+v", hint)
	}
	// A stale longer endpoint must not hide a shorter current-epoch endpoint.
	longer.CacheEpoch = indexTestCapability(100).CacheEpoch
	matches[0].Holder = longer
	if hint := production.CacheHintsForMatches(plan, matches, caps)[p.ID]; hint.CachedTokens != short.TokenCount {
		t.Fatalf("stale longer holder hid current shorter endpoint: %+v", hint)
	}
}

func TestCacheHolderIndexRequiresExecutableTier(t *testing.T) {
	_, p, capability := exactTestRegistry(t)
	short, long := exactTestAnchor(16, "c"), exactTestAnchor(32, "d")
	plan := exactTestPlan(short, long)
	ssd := indexKernelHolder{ProviderID: p.ID, Provider: p, ModelID: "model",
		CacheEpoch: capability.CacheEpoch, Anchor: short, StageMs: 100}
	memory := ssd
	memory.Anchor, memory.StageMs = long, 0
	for _, tc := range []struct {
		name, mode                  string
		ssdCap, memoryCap, ssdProof bool
		want                        string
	}{
		{"complete_precedes_longer_memory", protocol.PrefixCacheReadyBoundaryCheckpoint, true, true, true, "ssd"},
		{"complete_miss_does_not_fall_back_to_memory", protocol.PrefixCacheReadyBoundaryCheckpoint, true, true, false, ""},
		{"legacy_dual_tier_is_ambiguous", "", true, true, true, ""},
		{"ssd_only", "", true, false, true, "ssd"},
		{"memory_only", "", false, true, false, "memory"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			candidate := production.CacheRoutingCapability{Provider: p}
			if tc.ssdCap {
				candidate.Capability = capability
				candidate.Capability.ReadyBoundaryMode = tc.mode
			}
			if tc.memoryCap {
				candidate.MemoryCapability = capability
			}
			matches := []cachetracker.Match[*production.Provider]{{Holder: memory, Tier: "memory"}}
			if tc.ssdProof {
				matches = append(matches, cachetracker.Match[*production.Provider]{Holder: ssd, Tier: "ssd"})
			}
			hints := production.CacheHintsForMatches(plan, matches, map[string]production.CacheRoutingCapability{p.ID: candidate})
			if hints[p.ID].Tier != tc.want {
				t.Fatalf("tier=%q want=%q hints=%+v", hints[p.ID].Tier, tc.want, hints)
			}
			if tc.want == "" && len(hints) != 0 {
				t.Fatal("ambiguous selector created a hint")
			}
		})
	}
}
