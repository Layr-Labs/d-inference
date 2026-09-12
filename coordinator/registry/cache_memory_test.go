package registry

import (
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func memoryTestProvider(t *testing.T, r *Registry, id string, capability protocol.PrefixCacheV2Capability) *Provider {
	t.Helper()
	p := makeSchedulerProvider(t, r, id, "model", 100)
	p.mu.Lock()
	p.PrefillTPS = 100
	p.PrefixCacheProtocol = 2
	p.PrefixCacheMemoryModels = map[string]protocol.PrefixCacheV2Capability{"model": capability}
	p.BackendCapacity.Slots[0].ObservedPrefillTPS = 100
	p.mu.Unlock()
	return p
}

func memoryTestAttempt(t *testing.T, r *Registry, provider *Provider, capability protocol.PrefixCacheV2Capability, requestID string, plan CachePlan, seq uint64) (*PendingRequest, *protocol.PrefixCacheReadyV2Message) {
	t.Helper()
	pr := &PendingRequest{RequestID: requestID, Model: "model", CachePlan: plan}
	if err := prepareBoundTestCacheAttempt(r, pr, provider); err != nil {
		t.Fatal(err)
	}
	if preparedTestCacheMetadata(pr).CacheReceiptNonce == "" || !pr.CacheRoutingParticipates() {
		t.Fatal("resident-only capability did not receive an authenticated attempt")
	}
	prompt := plan.Boundaries[len(plan.Boundaries)-1]
	lookup := testV2Lookup(preparedTestCacheMetadata(pr).CacheReceiptNonce, capability, prompt, seq)
	lookup.RequestID, lookup.Tier = requestID, "memory"
	if !r.ApplyPrefixCacheLookupV2(provider.ID, lookup) {
		t.Fatal("resident lookup rejected")
	}
	ready := testV2Ready(preparedTestCacheMetadata(pr).CacheReceiptNonce, capability, prompt, seq+1)
	ready.RequestID, ready.Tier = requestID, "memory"
	return pr, ready
}

func memoryTestHints(r *Registry, plan CachePlan, now time.Time) map[string]cacheRoutingHint {
	if plan.generation == nil {
		plan = boundTestCachePlan(r, plan)
	}
	return r.cacheRoutingHints("model", plan, r.cacheRouting, r.cacheRouteKeys.route, CacheRoutingOn, now)
}

func TestMemoryRoutingOriginalAcrossProvidersUsesPublishedCheckpoint(t *testing.T) {
	r, _, capability := exactTestRegistry(t)
	removeTestProvider(r, "provider-a")
	a := memoryTestProvider(t, r, "machine-a", capability)
	b := memoryTestProvider(t, r, "machine-b", capability)
	checkpoint := exactTestAnchor(16, "c")  // Qwen's actual 4096-token checkpoint.
	originalEnd := exactTestAnchor(17, "d") // The 4352 floor is not itself reusable.
	continuation := exactTestAnchor(32, "e")
	original := boundTestCachePlan(r, exactTestPlan(checkpoint, originalEnd))
	longer := boundTestCachePlan(r, exactTestPlan(checkpoint, originalEnd, continuation))
	_, readyA := memoryTestAttempt(t, r, a, capability, "original-on-a", original, 1)
	readyA.ReadyAnchors = []protocol.PrefixCacheAnchor{checkpoint}
	readyA.ExpectedPrefillTokensSaved = checkpoint.TokenCount
	readyA.StageMs = 0 // Resident restore has no external SSD staging step.
	if !r.ApplyPrefixCacheReadyV2(a.ID, readyA) {
		t.Fatal("published checkpoint below prompt floor was rejected")
	}
	_, readyB := memoryTestAttempt(t, r, b, capability, "continuation-on-b", longer, 1)
	// Only this checkpoint was published: knowing the longer hash alone must
	// not manufacture a reusable checkpoint for the earlier original request.
	readyB.ReadyAnchors = []protocol.PrefixCacheAnchor{continuation}
	if !r.ApplyPrefixCacheReadyV2(b.ID, readyB) {
		t.Fatal("continuation checkpoint was rejected")
	}
	hints := memoryTestHints(r, original, time.Now())
	if len(hints) != 1 || hints[a.ID].CachedTokens != checkpoint.TokenCount || hints[a.ID].Tier != "memory" {
		t.Fatalf("original prefix inferred unproven boundaries: %+v", hints)
	}
	repeated := &PendingRequest{
		RequestID: "original-again", Model: "model", CachePlan: original,
		EstimatedPromptTokens: original.PromptTokenCount, RequestedMaxTokens: 128,
	}
	selected, decision := r.ReserveProviderEx("model", repeated)
	if selected != a || decision.CacheDiscountMs <= 0 || decision.CacheTier != "memory" {
		t.Fatalf("original did not return to its live holder: provider=%v decision=%+v", selected, decision)
	}
	selected.RemovePending(repeated.RequestID)
	r.SetProviderIdle(selected.ID)
	a.mu.Lock()
	a.BackendCapacity.Slots[0].NumWaiting = 10
	a.mu.Unlock()
	repeated.RequestID = "original-busy-holder"
	selected, decision = r.ReserveProviderEx("model", repeated)
	if selected != b {
		t.Fatalf("resident bonus overrode capacity/load: provider=%v decision=%+v", selected, decision)
	}
	otherTenant := original
	otherTenant.CacheScope = "different-tenant"
	if hints := memoryTestHints(r, otherTenant, time.Now()); len(hints) != 0 {
		t.Fatalf("resident evidence crossed tenant scope: %+v", hints)
	}
	selected.RemovePending(repeated.RequestID)
	r.SetProviderIdle(selected.ID)
	// B later confirms both real checkpoints. Once A disappears, the
	// original can use B's independently published 4096 boundary: no turn
	// affinity or history of which machine computed it is required.
	_, readyBoth := memoryTestAttempt(t, r, b, capability, "both-on-b", longer, 3)
	readyBoth.ReadyAnchors = []protocol.PrefixCacheAnchor{checkpoint, continuation}
	if !r.ApplyPrefixCacheReadyV2(b.ID, readyBoth) {
		t.Fatal("both checkpoints on B were rejected")
	}
	r.cacheRouting.disconnect(a.ID, cacheHolderRemovalDisconnect)
	removeTestProvider(r, a.ID)
	repeated.RequestID = "original-after-a-disconnected"
	selected, decision = r.ReserveProviderEx("model", repeated)
	if selected != b || decision.CacheDiscountMs <= 0 || decision.CacheTier != "memory" {
		t.Fatalf("live matching B did not serve original: provider=%v decision=%+v", selected, decision)
	}
}

func TestMemoryRoutingExpiryReplayMissAndSlotInvalidation(t *testing.T) {
	for _, action := range []string{"ttl", "miss", "slot-empty", "epoch", "disconnect", "connection-replaced"} {
		t.Run(action, func(t *testing.T) {
			r, _, capability := exactTestRegistry(t)
			removeTestProvider(r, "provider-a")
			p := memoryTestProvider(t, r, "memory", capability)
			p.mu.Lock()
			p.Models[0].WeightHash = capability.ModelAggregateHash
			p.mu.Unlock()
			anchor := exactTestAnchor(16, "c")
			plan := exactTestPlan(anchor)
			_, ready := memoryTestAttempt(t, r, p, capability, "seed", plan, 1)
			if !r.ApplyPrefixCacheReadyV2(p.ID, ready) {
				t.Fatal("ready rejected")
			}
			now := time.Now()
			hint := memoryTestHints(r, plan, now)[p.ID]
			if hint.CachedTokens == 0 {
				t.Fatal("seeded holder missing")
			}
			switch action {
			case "ttl":
				now = now.Add(cacheRoutingMemoryTTL + time.Millisecond)
			case "miss":
				memoryTestAttempt(t, r, p, capability, "evicted-miss", plan, 3)
			case "slot-empty", "epoch":
				memory := []protocol.PrefixCacheV2Capability{}
				if action == "epoch" {
					capability.CacheEpoch = "22222222-2222-2222-2222-222222222222"
					memory = append(memory, capability)
				}
				if _, err := r.UpdatePrefixCacheSnapshot(p.ID, false, 0, nil, &memory, nil, nil); err != nil {
					t.Fatal(err)
				}
				if hint.currentForProvider(p, "model") {
					t.Fatal("old hint survived slot capability mutation")
				}
			case "disconnect":
				r.cacheRouting.disconnect(p.ID, cacheHolderRemovalDisconnect)
			case "connection-replaced":
				removeTestProvider(r, p.ID)
				memoryTestProvider(t, r, p.ID, capability)
			}
			if hints := memoryTestHints(r, plan, now); len(hints) != 0 {
				t.Fatalf("stale holder survived %s: %+v", action, hints)
			}
			if r.ApplyPrefixCacheReadyV2(p.ID, ready) {
				t.Fatal("replayed receipt refreshed or resurrected resident evidence")
			}
		})
	}
}

func TestMemoryReceiptRejectsUnverifiedAndStaleClaims(t *testing.T) {
	for name, mutate := range map[string]func(*protocol.PrefixCacheReadyV2Message){
		"nonce":    func(m *protocol.PrefixCacheReadyV2Message) { m.CacheReceiptNonce = "unknown" },
		"request":  func(m *protocol.PrefixCacheReadyV2Message) { m.RequestID = "other" },
		"model":    func(m *protocol.PrefixCacheReadyV2Message) { m.ModelID = "other" },
		"weight":   func(m *protocol.PrefixCacheReadyV2Message) { m.ModelAggregateHash = strings.Repeat("e", 64) },
		"contract": func(m *protocol.PrefixCacheReadyV2Message) { m.PromptContractID = strings.Repeat("f", 64) },
		"epoch":    func(m *protocol.PrefixCacheReadyV2Message) { m.CacheEpoch = "22222222-2222-2222-2222-222222222222" },
		"page-hash": func(m *protocol.PrefixCacheReadyV2Message) {
			m.ReadyAnchors[0].TokenCount = 16
			m.ExpectedPrefillTokensSaved = 16
		},
		"unknown-hash": func(m *protocol.PrefixCacheReadyV2Message) { m.ReadyAnchors[0].ChainHash = strings.Repeat("e", 64) },
		"generated-anchor": func(m *protocol.PrefixCacheReadyV2Message) {
			m.ReadyAnchors[0] = exactTestAnchor(32, "e")
			m.ExpectedPrefillTokensSaved = 8192
		},
		"too-many-anchors":  func(m *protocol.PrefixCacheReadyV2Message) { m.ReadyAnchors = make([]protocol.PrefixCacheAnchor, 17) },
		"replayed-sequence": func(m *protocol.PrefixCacheReadyV2Message) { m.CacheSeq = 1 },
		"ssd-tier":          func(m *protocol.PrefixCacheReadyV2Message) { m.Tier = "ssd" },
	} {
		t.Run(name, func(t *testing.T) {
			r, _, capability := exactTestRegistry(t)
			removeTestProvider(r, "provider-a")
			p := memoryTestProvider(t, r, "memory", capability)
			_, ready := memoryTestAttempt(t, r, p, capability, "seed", exactTestPlan(exactTestAnchor(16, "c")), 1)
			mutate(ready)
			if r.ApplyPrefixCacheReadyV2(p.ID, ready) {
				t.Fatal("accepted invalid resident publication")
			}
			if holders, _ := r.CacheRoutingStateCounts(); holders != 0 {
				t.Fatalf("invalid receipt created %d holders", holders)
			}
		})
	}
}

func TestMemoryAndSSDReceiptStateIsIndependent(t *testing.T) {
	r, _, capability := exactTestRegistry(t)
	removeTestProvider(r, "provider-a")
	p := memoryTestProvider(t, r, "both", capability)
	p.mu.Lock()
	p.PrefixCacheV2Models = map[string]protocol.PrefixCacheV2Capability{"model": capability}
	p.mu.Unlock()
	anchor := exactTestAnchor(16, "c")
	plan := exactTestPlan(anchor)
	pr, ready := memoryTestAttempt(t, r, p, capability, "both", plan, 1)
	if !r.ApplyPrefixCacheReadyV2(p.ID, ready) {
		t.Fatal("resident ready rejected")
	}
	lookupSSD := testV2Lookup(preparedTestCacheMetadata(pr).CacheReceiptNonce, capability, anchor, 1)
	lookupSSD.RequestID = pr.RequestID
	if !r.ApplyPrefixCacheLookupV2(p.ID, lookupSSD) {
		t.Fatal("resident lookup/sequence consumed independent SSD state")
	}
	readySSD := testV2Ready(preparedTestCacheMetadata(pr).CacheReceiptNonce, capability, anchor, 2)
	readySSD.RequestID = pr.RequestID
	if !r.ApplyPrefixCacheReadyV2(p.ID, readySSD) {
		t.Fatal("SSD ready rejected")
	}
	if holders, _ := r.CacheRoutingStateCounts(); holders != 2 {
		t.Fatalf("equal epochs aliased tier holders: %d", holders)
	}
	now := time.Now().Add(cacheRoutingMemoryTTL + time.Millisecond)
	matches := r.cacheRouting.matchingHolders(boundTestCachePlan(r, plan), r.cacheRouteKeys.route, CacheRoutingOn, now)
	if len(matches) != 1 || matches[0].Tier != "ssd" {
		t.Fatalf("resident expiry removed independent durable evidence: %+v", matches)
	}
	// The old dual-tier capability has no negotiated execution selector;
	// retaining independent evidence does not authorize a routing credit.
	if hints := memoryTestHints(r, plan, now); len(hints) != 0 {
		t.Fatalf("ambiguous dual-tier advertisement influenced routing: %+v", hints)
	}
}

func TestMemoryCapabilityRegistrationAndHeartbeatAreAdditive(t *testing.T) {
	capability := exactTestCapability("11111111-1111-1111-1111-111111111111")
	msg := protocol.RegisterMessage{
		Models:                  []protocol.ModelInfo{{ID: "model", WeightHash: capability.ModelAggregateHash}},
		PrefixCacheProtocol:     2,
		PrefixCacheMemoryModels: []protocol.PrefixCacheV2Capability{capability},
	}
	r := New(testLogger())
	if err := r.ValidatePrefixCacheRegistration(&msg); err != nil {
		t.Fatal(err)
	}
	p := r.Register("resident-only", nil, &msg)
	if len(p.PrefixCacheV2Models) != 0 || len(p.PrefixCacheMemoryModels) != 1 {
		t.Fatal("resident registration manufactured a durable SSD capability")
	}
	if _, err := r.UpdatePrefixCacheSnapshot(p.ID, true, 2, nil, nil, nil, nil); err != nil {
		t.Fatal(err)
	}
	if len(p.PrefixCacheMemoryModels) != 1 {
		t.Fatal("omitted resident snapshot erased its live inventory")
	}
	invalid := capability
	invalid.BlockSize = 16
	badMemory := []protocol.PrefixCacheV2Capability{invalid}
	if _, err := r.UpdatePrefixCacheSnapshot(p.ID, false, 0, nil, &badMemory, nil, nil); err == nil {
		t.Fatal("accepted physical page size instead of the shared block contract")
	}
	if p.PrefixCacheMemoryModels["model"] != capability {
		t.Fatal("malformed update partially changed live inventory")
	}
	if err := r.UpdatePrefixCacheCapabilities(p.ID, 1, nil); err != nil {
		t.Fatal(err)
	}
	if len(p.PrefixCacheMemoryModels) != 0 {
		t.Fatal("protocol downgrade kept resident evidence enabled")
	}
	for _, mutate := range []func(*protocol.RegisterMessage){
		func(m *protocol.RegisterMessage) { m.PrefixCacheProtocol = 1 },
		func(m *protocol.RegisterMessage) {
			m.PrefixCacheMemoryModels = []protocol.PrefixCacheV2Capability{capability, capability}
		},
		func(m *protocol.RegisterMessage) { m.Models = nil },
		func(m *protocol.RegisterMessage) { m.PrefixCacheMemoryModels = badMemory },
	} {
		invalid := msg
		mutate(&invalid)
		if err := r.ValidatePrefixCacheRegistration(&invalid); err == nil {
			t.Fatal("accepted malformed resident registration")
		}
	}
}
