package registry_test

import (
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachetracker"
	"github.com/eigeninference/d-inference/coordinator/protocol"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestMemoryRoutingOriginalAcrossProvidersUsesPublishedCheckpoint(t *testing.T) {
	r, f := newCheckpointPricingFixture(t)
	r.Disconnect("provider-a")
	capability := exactTestCapability("11111111-1111-1111-1111-111111111111")
	a := memoryTestProvider(t, r, "machine-a", capability)
	b := memoryTestProvider(t, r, "machine-b", capability)
	checkpoint := exactTestAnchor(16, "c")  // Qwen's actual 4096-token checkpoint.
	originalEnd := exactTestAnchor(17, "d") // The 4352 floor is not itself reusable.
	continuation := exactTestAnchor(32, "e")
	original := f.plans.bind(exactTestPlan(checkpoint, originalEnd))
	longer := f.plans.bind(exactTestPlan(checkpoint, originalEnd, continuation))
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
	hints := f.hints(original, time.Now())
	if len(hints) != 1 || hints[a.ID].CachedTokens != checkpoint.TokenCount || hints[a.ID].Tier != "memory" {
		t.Fatalf("original prefix inferred unproven boundaries: %+v", hints)
	}
	repeated := &production.PendingRequest{
		RequestID: "original-again", Model: "model", CachePlan: original,
		EstimatedPromptTokens: original.PromptTokenCount, RequestedMaxTokens: 128,
	}
	selected, decision := r.ReserveProviderEx("model", repeated)
	if selected != a || decision.CacheDiscountMs <= 0 || decision.CacheTier != "memory" {
		t.Fatalf("original did not return to its live holder: provider=%v decision=%+v", selected, decision)
	}
	selected.RemovePending(repeated.RequestID)
	r.SetProviderIdle(selected.ID)
	a.Mu().Lock()
	a.BackendCapacity.Slots[0].NumWaiting = 10
	a.Mu().Unlock()
	repeated.RequestID = "original-busy-holder"
	selected, decision = r.ReserveProviderEx("model", repeated)
	if selected != b {
		t.Fatalf("resident bonus overrode capacity/load: provider=%v decision=%+v", selected, decision)
	}
	otherTenant := original
	otherTenant.CacheScope = "different-tenant"
	if hints := f.hints(otherTenant, time.Now()); len(hints) != 0 {
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
	r.Disconnect(a.ID)
	repeated.RequestID = "original-after-a-disconnected"
	selected, decision = r.ReserveProviderEx("model", repeated)
	if selected != b || decision.CacheDiscountMs <= 0 || decision.CacheTier != "memory" {
		t.Fatalf("live matching B did not serve original: provider=%v decision=%+v", selected, decision)
	}
}

func TestMemoryRoutingExpiryReplayMissAndSlotInvalidation(t *testing.T) {
	for _, action := range []string{"ttl", "miss", "slot-empty", "epoch", "disconnect", "connection-replaced"} {
		t.Run(action, func(t *testing.T) {
			var maintenance production.CacheMaintainer
			paused := &pausedMemoryInvalidation{entered: make(chan struct{}), release: make(chan struct{})}
			r, f := newCheckpointPricingFixture(t, production.Dependencies{Cache: production.CacheDependencies{
				Maintenance: func(m production.CacheMaintenance) production.CacheMaintainer {
					maintenance = m
					if action == "connection-replaced" {
						paused.CacheMaintainer = m
						return paused
					}
					return m
				},
			}})
			r.Disconnect("provider-a")
			capability := exactTestCapability("11111111-1111-1111-1111-111111111111")
			p := memoryTestProvider(t, r, "memory", capability)
			p.Mu().Lock()
			p.Models[0].WeightHash = capability.ModelAggregateHash
			p.Mu().Unlock()
			anchor := exactTestAnchor(16, "c")
			plan := f.plans.bind(exactTestPlan(anchor))
			_, ready := memoryTestAttempt(t, r, p, capability, "seed", plan, 1)
			if !r.ApplyPrefixCacheReadyV2(p.ID, ready) {
				t.Fatal("ready rejected")
			}
			now := time.Now()
			hint := f.hints(plan, now)[p.ID]
			if hint.CachedTokens == 0 {
				t.Fatal("seeded holder missing")
			}
			switch action {
			case "ttl":
				now = now.Add(cachetracker.MemoryTTL + time.Millisecond)
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
				p.Mu().Lock()
				current := hint.CurrentForProviderLocked(p, "model")
				p.Mu().Unlock()
				if current {
					t.Fatal("old hint survived slot capability mutation")
				}
			case "disconnect":
				maintenance.InvalidateProviderEvidence(p.ID, cachetracker.RemovalDisconnect, true)
			case "connection-replaced":
				done := make(chan struct{})
				go func() {
					r.Disconnect(p.ID)
					close(done)
				}()
				t.Cleanup(func() { close(paused.release); <-done })
				<-paused.entered
				memoryTestProvider(t, r, p.ID, capability)
			}
			if hints := f.hints(plan, now); len(hints) != 0 {
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
			r, f := newCheckpointPricingFixture(t)
			r.Disconnect("provider-a")
			capability := exactTestCapability("11111111-1111-1111-1111-111111111111")
			p := memoryTestProvider(t, r, "memory", capability)
			_, ready := memoryTestAttempt(t, r, p, capability, "seed", f.plans.bind(exactTestPlan(exactTestAnchor(16, "c"))), 1)
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
	r, f := newCheckpointPricingFixture(t)
	r.Disconnect("provider-a")
	capability := exactTestCapability("11111111-1111-1111-1111-111111111111")
	p := memoryTestProvider(t, r, "both", capability)
	p.Mu().Lock()
	p.PrefixCacheV2Models = map[string]protocol.PrefixCacheV2Capability{"model": capability}
	p.Mu().Unlock()
	anchor := exactTestAnchor(16, "c")
	plan := f.plans.bind(exactTestPlan(anchor))
	pr, ready := memoryTestAttempt(t, r, p, capability, "both", plan, 1)
	if !r.ApplyPrefixCacheReadyV2(p.ID, ready) {
		t.Fatal("resident ready rejected")
	}
	lookupSSD := fenceTestV2Lookup(pr.CacheAttemptSnapshot().MetadataMessage().CacheReceiptNonce, capability, anchor, 1)
	lookupSSD.RequestID = pr.RequestID
	if !r.ApplyPrefixCacheLookupV2(p.ID, lookupSSD) {
		t.Fatal("resident lookup/sequence consumed independent SSD state")
	}
	readySSD := fenceTestV2Ready(pr.CacheAttemptSnapshot().MetadataMessage().CacheReceiptNonce, capability, anchor, 2)
	readySSD.RequestID = pr.RequestID
	if !r.ApplyPrefixCacheReadyV2(p.ID, readySSD) {
		t.Fatal("SSD ready rejected")
	}
	if holders, _ := r.CacheRoutingStateCounts(); holders != 2 {
		t.Fatalf("equal epochs aliased tier holders: %d", holders)
	}
	now := time.Now().Add(cachetracker.MemoryTTL + time.Millisecond)
	matches := f.query.(production.CacheHintQuery).MatchBoundaries(plan, f.routeKey, production.CacheRoutingOn, now)
	if len(matches) != 1 || matches[0].Tier != "ssd" {
		t.Fatalf("resident expiry removed independent durable evidence: %+v", matches)
	}
	// The old dual-tier capability has no negotiated execution selector;
	// retaining independent evidence does not authorize a routing credit.
	if hints := f.hints(plan, now); len(hints) != 0 {
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
	r := production.New(testLogger())
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
