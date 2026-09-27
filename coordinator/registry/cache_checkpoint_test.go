package registry

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func checkpointTestProvider(t *testing.T, r *Registry, id string, capability protocol.PrefixCacheV2Capability) *Provider {
	t.Helper()
	p := makeSchedulerProvider(t, r, id, "model", 100)
	p.mu.Lock()
	p.PrefillTPS = 100
	p.PrefixCacheProtocol = 2
	p.PrefixCacheV2Models = map[string]protocol.PrefixCacheV2Capability{"model": capability}
	p.Models[0].WeightHash = capability.ModelAggregateHash
	p.BackendCapacity.Slots[0].ObservedPrefillTPS = 100
	p.mu.Unlock()
	return p
}

func checkpointTestAttempt(t *testing.T, r *Registry, p *Provider, capability protocol.PrefixCacheV2Capability, id string, plan CachePlan, sequence uint64) (*PendingRequest, *protocol.PrefixCacheReadyV2Message) {
	t.Helper()
	pr := &PendingRequest{RequestID: id, Model: "model", CachePlan: plan}
	if err := prepareBoundTestCacheAttempt(r, pr, p); err != nil {
		t.Fatal(err)
	}
	if preparedTestCacheMetadata(pr).CacheReceiptNonce == "" || preparedTestCacheMetadata(pr).CacheReceiptBoundaryMode != capability.ReadyBoundaryMode {
		t.Fatalf("checkpoint attempt lost negotiated mode: %+v", pr)
	}
	prompt := plan.Boundaries[len(plan.Boundaries)-1]
	lookup := testV2Lookup(preparedTestCacheMetadata(pr).CacheReceiptNonce, capability, prompt, sequence)
	lookup.RequestID = id
	if !r.ApplyPrefixCacheLookupV2(p.ID, lookup) {
		t.Fatal("lookup rejected")
	}
	ready := testV2Ready(preparedTestCacheMetadata(pr).CacheReceiptNonce, capability, prompt, sequence+1)
	ready.RequestID = id
	return pr, ready
}

func TestCheckpointSSDRoutesOnlyCommittedOriginalAcrossProviders(t *testing.T) {
	r, _, capability := exactTestRegistry(t)
	removeTestProvider(r, "provider-a")
	capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
	a := checkpointTestProvider(t, r, "machine-a", capability)
	b := checkpointTestProvider(t, r, "machine-b", capability)
	checkpoint := exactTestAnchor(16, "c")
	originalFloor := exactTestAnchor(17, "d")
	longerCheckpoint := exactTestAnchor(32, "e")
	original := boundTestCachePlan(r, exactTestPlan(checkpoint, originalFloor))
	longer := boundTestCachePlan(r, exactTestPlan(checkpoint, originalFloor, longerCheckpoint))
	_, readyA := checkpointTestAttempt(t, r, a, capability, "original-on-a", original, 1)
	if hints := memoryTestHints(r, original, time.Now()); len(hints) != 0 {
		t.Fatalf("lookup miss advertised uncommitted checkpoint: %+v", hints)
	}
	readyA.ReadyAnchors = []protocol.PrefixCacheAnchor{checkpoint}
	readyA.ExpectedPrefillTokensSaved = checkpoint.TokenCount
	if !r.ApplyPrefixCacheReadyV2(a.ID, readyA) {
		t.Fatal("committed checkpoint below prompt floor was rejected")
	}
	_, readyB := checkpointTestAttempt(t, r, b, capability, "longer-on-b", longer, 1)
	readyB.ReadyAnchors = []protocol.PrefixCacheAnchor{longerCheckpoint}
	if !r.ApplyPrefixCacheReadyV2(b.ID, readyB) {
		t.Fatal("longer checkpoint rejected")
	}
	hints := memoryTestHints(r, original, time.Now())
	if len(hints) != 1 || hints[a.ID].Tier != "ssd" || hints[a.ID].CachedTokens != checkpoint.TokenCount {
		t.Fatalf("invented an uncommitted original checkpoint: %+v", hints)
	}
	repeat := &PendingRequest{RequestID: "original-again", Model: "model", CachePlan: original,
		EstimatedPromptTokens: original.PromptTokenCount, RequestedMaxTokens: 128}
	selected, decision := r.ReserveProviderEx("model", repeat)
	if selected != a || decision.CacheDiscountMs <= 0 {
		t.Fatalf("original did not select live durable holder: provider=%v decision=%+v", selected, decision)
	}
	selected.RemovePending(repeat.RequestID)
	r.SetProviderIdle(selected.ID)
	a.mu.Lock()
	a.BackendCapacity.Slots[0].NumWaiting = 10
	a.mu.Unlock()
	repeat.RequestID = "busy-original-holder"
	selected, _ = r.ReserveProviderEx("model", repeat)
	if selected != b {
		t.Fatal("durable cache bonus overrode provider load")
	}
	selected.RemovePending(repeat.RequestID)
	r.SetProviderIdle(selected.ID)
	_, readyBoth := checkpointTestAttempt(t, r, b, capability, "both-on-b", longer, 3)
	readyBoth.ReadyAnchors = []protocol.PrefixCacheAnchor{checkpoint, longerCheckpoint}
	if !r.ApplyPrefixCacheReadyV2(b.ID, readyBoth) {
		t.Fatal("two actually committed checkpoints rejected")
	}
	r.cacheRouting.disconnect(a.ID, cacheHolderRemovalDisconnect)
	removeTestProvider(r, a.ID)
	repeat.RequestID = "original-after-a-disconnected"
	selected, decision = r.ReserveProviderEx("model", repeat)
	if selected != b || decision.CacheDiscountMs <= 0 {
		t.Fatalf("B could not serve its independently committed original: provider=%v decision=%+v", selected, decision)
	}
	otherTenant := original
	otherTenant.CacheScope = "another-tenant"
	if hints := memoryTestHints(r, otherTenant, time.Now()); len(hints) != 0 {
		t.Fatal("durable checkpoint holder crossed tenant scope")
	}
}

func TestCheckpointSSDDoesNotWeakenLegacyReadyContract(t *testing.T) {
	for _, mode := range []string{"", protocol.PrefixCacheReadyBoundaryCheckpoint} {
		t.Run("mode="+mode, func(t *testing.T) {
			r, p, capability := exactTestRegistry(t)
			capability.ReadyBoundaryMode = mode
			p.PrefixCacheV2Models["model"] = capability
			checkpoint, floor := exactTestAnchor(16, "c"), exactTestAnchor(17, "d")
			pr, ready := checkpointTestAttempt(t, r, p, capability, "donor", exactTestPlan(checkpoint, floor), 1)
			ready.ReadyAnchors = []protocol.PrefixCacheAnchor{checkpoint}
			ready.ExpectedPrefillTokensSaved = checkpoint.TokenCount
			if accepted := r.ApplyPrefixCacheReadyV2(p.ID, ready); accepted != (mode != "") {
				t.Fatalf("accepted=%v mode=%q", accepted, mode)
			}
			r.ForgetCacheAttempt(pr)
			if preparedTestCacheMetadata(pr).CacheReceiptBoundaryMode != "" || preparedTestCacheMetadata(pr).CacheReceiptNonce != "" {
				t.Fatal("attempt reset retained checkpoint negotiation")
			}
		})
	}
}

func TestCheckpointSSDRejectsUnverifiedReadyAndReplay(t *testing.T) {
	mutations := map[string]func(*protocol.PrefixCacheReadyV2Message){
		"unknown nonce":    func(m *protocol.PrefixCacheReadyV2Message) { m.CacheReceiptNonce = "unknown" },
		"wrong epoch":      func(m *protocol.PrefixCacheReadyV2Message) { m.CacheEpoch = "22222222-2222-2222-2222-222222222222" },
		"wrong model hash": func(m *protocol.PrefixCacheReadyV2Message) { m.ModelAggregateHash = exactTestAnchor(16, "f").ChainHash },
		"unverified checkpoint": func(m *protocol.PrefixCacheReadyV2Message) {
			m.ReadyAnchors[0].ChainHash = exactTestAnchor(16, "f").ChainHash
		},
		"generated boundary": func(m *protocol.PrefixCacheReadyV2Message) {
			m.ReadyAnchors = []protocol.PrefixCacheAnchor{exactTestAnchor(32, "e")}
			m.ExpectedPrefillTokensSaved = 8192
		},
		"duplicate anchor": func(m *protocol.PrefixCacheReadyV2Message) {
			m.ReadyAnchors = append(m.ReadyAnchors, m.ReadyAnchors[0])
		},
		"incomplete checkpoint": func(m *protocol.PrefixCacheReadyV2Message) {
			m.RequiredRecomputeTokens = 256
			m.ExpectedPrefillTokensSaved -= 256
		},
		"old sequence":       func(m *protocol.PrefixCacheReadyV2Message) { m.CacheSeq = 1 },
		"unknown stage cost": func(m *protocol.PrefixCacheReadyV2Message) { m.StageMs = 0 },
	}
	for name, mutate := range mutations {
		t.Run(name, func(t *testing.T) {
			r, p, capability := exactTestRegistry(t)
			capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
			p.PrefixCacheV2Models["model"] = capability
			checkpoint, floor := exactTestAnchor(16, "c"), exactTestAnchor(17, "d")
			_, ready := checkpointTestAttempt(t, r, p, capability, "donor", exactTestPlan(checkpoint, floor), 1)
			ready.ReadyAnchors = []protocol.PrefixCacheAnchor{checkpoint}
			ready.ExpectedPrefillTokensSaved = checkpoint.TokenCount
			mutate(ready)
			if r.ApplyPrefixCacheReadyV2(p.ID, ready) {
				t.Fatal("invalid committed-checkpoint claim accepted")
			}
		})
	}
}

func TestCheckpointSSDInvalidatesMissingCorruptEpochAndSlotEvidence(t *testing.T) {
	for _, action := range []string{"miss_absent", "miss_corrupt", "epoch", "mode", "slot-empty", "disconnect"} {
		t.Run(action, func(t *testing.T) {
			r, _, capability := exactTestRegistry(t)
			removeTestProvider(r, "provider-a")
			capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
			p := checkpointTestProvider(t, r, "holder", capability)
			checkpoint := exactTestAnchor(16, "c")
			plan := exactTestPlan(checkpoint, exactTestAnchor(17, "d"))
			_, ready := checkpointTestAttempt(t, r, p, capability, "donor", plan, 1)
			ready.ReadyAnchors = []protocol.PrefixCacheAnchor{checkpoint}
			ready.ExpectedPrefillTokensSaved = checkpoint.TokenCount
			if !r.ApplyPrefixCacheReadyV2(p.ID, ready) {
				t.Fatal("ready rejected")
			}
			if len(memoryTestHints(r, plan, time.Now())) != 1 {
				t.Fatal("no initial holder")
			}
			switch action {
			case "miss_absent", "miss_corrupt":
				pr := &PendingRequest{RequestID: "missing", Model: "model", CachePlan: plan}
				if err := prepareBoundTestCacheAttempt(r, pr, p); err != nil {
					t.Fatal(err)
				}
				lookup := testV2Lookup(preparedTestCacheMetadata(pr).CacheReceiptNonce, capability, plan.Boundaries[1], 3)
				lookup.RequestID, lookup.Outcome = pr.RequestID, action
				if !r.ApplyPrefixCacheLookupV2(p.ID, lookup) {
					t.Fatal("miss rejected")
				}
			case "epoch":
				capability.CacheEpoch = "22222222-2222-2222-2222-222222222222"
				if err := r.UpdatePrefixCacheCapabilities(p.ID, 2, []protocol.PrefixCacheV2Capability{capability}); err != nil {
					t.Fatal(err)
				}
			case "slot-empty":
				if err := r.UpdatePrefixCacheCapabilities(p.ID, 2, nil); err != nil {
					t.Fatal(err)
				}
			case "mode":
				capability.ReadyBoundaryMode = ""
				if err := r.UpdatePrefixCacheCapabilities(p.ID, 2, []protocol.PrefixCacheV2Capability{capability}); err != nil {
					t.Fatal(err)
				}
			case "disconnect":
				r.cacheRouting.disconnect(p.ID, cacheHolderRemovalDisconnect)
			}
			if hints := memoryTestHints(r, plan, time.Now()); len(hints) != 0 {
				t.Fatalf("stale holder: %+v", hints)
			}
		})
	}
}

func TestCheckpointModeValidationAndMemoryRetryReset(t *testing.T) {
	r, _, capability := exactTestRegistry(t)
	removeTestProvider(r, "provider-a")
	models := map[string]protocol.ModelInfo{"model": {ID: "model", WeightHash: capability.ModelAggregateHash}}
	capability.ReadyBoundaryMode = "future-unknown"
	if _, err := validatePrefixCacheCapabilities(2, []protocol.PrefixCacheV2Capability{capability}, models); err == nil {
		t.Fatal("unknown boundary mode accepted")
	}
	capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
	if _, err := validateMemoryPrefixCacheCapabilities(2, []protocol.PrefixCacheV2Capability{capability}, models); err == nil {
		t.Fatal("durable checkpoint mode accepted on resident tier")
	}
	p := checkpointTestProvider(t, r, "ssd", capability)
	plan := exactTestPlan(exactTestAnchor(16, "c"))
	pr, _ := checkpointTestAttempt(t, r, p, capability, "retry", plan, 1)
	capability.ReadyBoundaryMode = ""
	memory := memoryTestProvider(t, r, "memory", capability)
	if err := prepareBoundTestCacheAttempt(r, pr, memory); err != nil {
		t.Fatal(err)
	}
	if preparedTestCacheMetadata(pr).CacheReceiptBoundaryMode != "" {
		t.Fatal("SSD echo leaked into memory-only retry")
	}
	r.ForgetCacheAttempt(pr)
	if preparedTestCacheMetadata(pr).CacheReceiptBoundaryMode != "" {
		t.Fatal("SSD echo leaked into cold fallback")
	}
}
