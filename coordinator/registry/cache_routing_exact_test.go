package registry

import (
	"encoding/base64"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func exactTestAnchor(blocks int, hexByte string) protocol.PrefixCacheAnchor {
	return protocol.PrefixCacheAnchor{
		TokenCount: blocks * int(promptcontract.BlockSize),
		ChainHash:  strings.Repeat(hexByte, 64),
	}
}

func exactTestPlan(boundaries ...protocol.PrefixCacheAnchor) CachePlan {
	return CachePlan{
		ModelAggregateHash: strings.Repeat("a", 64),
		PromptContractID:   strings.Repeat("b", 64),
		CacheScope:         "opaque-scope",
		PromptTokenCount:   boundaries[len(boundaries)-1].TokenCount,
		Boundaries:         boundaries,
	}
}

func exactTestCapability(epoch string) protocol.PrefixCacheV2Capability {
	return protocol.PrefixCacheV2Capability{
		ModelID:            "model",
		ModelAggregateHash: strings.Repeat("a", 64),
		PromptContractID:   strings.Repeat("b", 64),
		BlockHashVersion:   promptcontract.BlockHashVersion,
		BlockSize:          promptcontract.BlockSize,
		CacheEpoch:         epoch,
		Enabled:            true,
		Ready:              true,
	}
}

func exactTestRegistry(t *testing.T) (*Registry, *Provider, protocol.PrefixCacheV2Capability) {
	t.Helper()
	r := New(testLogger())
	err := r.ConfigureCacheRouting(CacheRoutingConfig{
		Mode:            CacheRoutingOn,
		TTL:             time.Minute,
		MaxHolders:      8,
		MaxDiscountMs:   1_000,
		MaxCostFraction: .35,
		MasterKey: base64.RawURLEncoding.EncodeToString(
			[]byte("0123456789abcdef0123456789abcdef")),
	})
	if err != nil {
		t.Fatal(err)
	}
	capability := exactTestCapability("11111111-1111-1111-1111-111111111111")
	provider := &Provider{
		ID:                  "provider-a",
		PrefixCacheProtocol: 2,
		PrefixCacheV2Models: map[string]protocol.PrefixCacheV2Capability{"model": capability},
	}
	r.mu.Lock()
	r.providers[provider.ID] = provider
	r.mu.Unlock()
	return r, provider, capability
}

func TestExactV2ReadyCreatesLongestPrefixHolderAndMissInvalidates(t *testing.T) {
	r, provider, capability := exactTestRegistry(t)
	a1 := exactTestAnchor(1, "c")
	a2 := exactTestAnchor(2, "d")
	a3 := exactTestAnchor(3, "e")
	a4 := exactTestAnchor(4, "f")
	initial := exactTestPlan(a1, a2)
	pr := &PendingRequest{RequestID: "request-1", Model: "model", CachePlan: initial}
	if err := r.PrepareCacheAttempt(pr, provider); err != nil {
		t.Fatal(err)
	}
	if pr.CacheReceiptNonce == "" || !pr.CacheRoutingParticipates() {
		t.Fatal("protocol-v2 attempt was not activated")
	}
	lookup := &protocol.PrefixCacheLookupV2Message{
		RequestID: pr.RequestID, CacheReceiptNonce: pr.CacheReceiptNonce,
		ModelID: "model", ModelAggregateHash: capability.ModelAggregateHash,
		PromptContractID: capability.PromptContractID, CacheEpoch: capability.CacheEpoch,
		CacheSeq: 1, PromptAnchor: a2, Outcome: "miss_absent", Tier: "ssd", StageMs: 1,
	}
	if !r.ApplyPrefixCacheLookupV2(provider.ID, lookup) {
		t.Fatal("valid lookup proof was rejected")
	}
	ready := &protocol.PrefixCacheReadyV2Message{
		RequestID: pr.RequestID, CacheReceiptNonce: pr.CacheReceiptNonce,
		ModelID: "model", ModelAggregateHash: capability.ModelAggregateHash,
		PromptContractID: capability.PromptContractID, CacheEpoch: capability.CacheEpoch,
		CacheSeq: 2, Outcome: "ready", Tier: "ssd", ReadyAnchors: []protocol.PrefixCacheAnchor{a2, a3},
		ExpectedPrefillTokensSaved: a3.TokenCount, StageMs: 2,
	}
	if !r.ApplyPrefixCacheReadyV2(provider.ID, ready) {
		t.Fatal("durable ready proof was rejected")
	}

	future := exactTestPlan(a1, a2, a3, a4)
	hints := r.cacheRouting.hints(
		future,
		map[string]cacheRoutingCapability{
			provider.ID: {Provider: provider, Capability: capability},
		},
		r.cacheRouteKeys.route,
		CacheRoutingOn,
		time.Now(),
	)
	hint, ok := hints[provider.ID]
	if !ok || hint.CachedTokens != a3.TokenCount ||
		hint.PrefillTokensSaved != a3.TokenCount {
		t.Fatalf("longest exact hint = %+v, present=%t", hint, ok)
	}
	divergent := exactTestPlan(a1, exactTestAnchor(2, "1"))
	otherAccount := future
	otherAccount.CacheScope = "different-account-scope"
	otherBuild := future
	otherBuild.ModelAggregateHash = strings.Repeat("2", 64)
	otherBuildCapability := capability
	otherBuildCapability.ModelAggregateHash = otherBuild.ModelAggregateHash
	otherContract := future
	otherContract.PromptContractID = strings.Repeat("3", 64)
	otherContractCapability := capability
	otherContractCapability.PromptContractID = otherContract.PromptContractID
	for name, variant := range map[string]struct {
		plan       CachePlan
		capability protocol.PrefixCacheV2Capability
	}{
		"divergent_history": {plan: divergent, capability: capability},
		"account":           {plan: otherAccount, capability: capability},
		"build":             {plan: otherBuild, capability: otherBuildCapability},
		"contract":          {plan: otherContract, capability: otherContractCapability},
	} {
		if hints := r.cacheRouting.hints(
			variant.plan,
			map[string]cacheRoutingCapability{
				provider.ID: {Provider: provider, Capability: variant.capability},
			},
			r.cacheRouteKeys.route,
			CacheRoutingOn,
			time.Now(),
		); len(hints) != 0 {
			t.Fatalf("%s crossed exact routing isolation: %+v", name, hints)
		}
	}

	missPR := &PendingRequest{RequestID: "request-2", Model: "model", CachePlan: future}
	if err := r.PrepareCacheAttempt(missPR, provider); err != nil {
		t.Fatal(err)
	}
	miss := &protocol.PrefixCacheLookupV2Message{
		RequestID: missPR.RequestID, CacheReceiptNonce: missPR.CacheReceiptNonce,
		ModelID: "model", ModelAggregateHash: capability.ModelAggregateHash,
		PromptContractID: capability.PromptContractID, CacheEpoch: capability.CacheEpoch,
		CacheSeq: 3, PromptAnchor: a4, Outcome: "miss_absent", Tier: "ssd", StageMs: 1,
	}
	if !r.ApplyPrefixCacheLookupV2(provider.ID, miss) {
		t.Fatal("valid miss proof was rejected")
	}
	if hints := r.cacheRouting.hints(
		future,
		map[string]cacheRoutingCapability{
			provider.ID: {Provider: provider, Capability: capability},
		},
		r.cacheRouteKeys.route,
		CacheRoutingOn,
		time.Now(),
	); len(hints) != 0 {
		t.Fatalf("miss left stale exact holders: %+v", hints)
	}
}

func TestExactV2CoordinatorRestartDropsEphemeralRoutingState(t *testing.T) {
	r, provider, capability := exactTestRegistry(t)
	prompt := exactTestAnchor(2, "c")
	final := exactTestAnchor(3, "d")
	plan := exactTestPlan(exactTestAnchor(1, "b"), prompt)
	pr := &PendingRequest{RequestID: "request-before-restart", Model: "model", CachePlan: plan}
	if err := r.PrepareCacheAttempt(pr, provider); err != nil {
		t.Fatal(err)
	}
	lookup := &protocol.PrefixCacheLookupV2Message{
		RequestID: pr.RequestID, CacheReceiptNonce: pr.CacheReceiptNonce,
		ModelID: "model", ModelAggregateHash: capability.ModelAggregateHash,
		PromptContractID: capability.PromptContractID, CacheEpoch: capability.CacheEpoch,
		CacheSeq: 1, PromptAnchor: prompt, Outcome: "miss_absent", Tier: "ssd", StageMs: 1,
	}
	if !r.ApplyPrefixCacheLookupV2(provider.ID, lookup) {
		t.Fatal("valid lookup proof was rejected")
	}
	ready := &protocol.PrefixCacheReadyV2Message{
		RequestID: pr.RequestID, CacheReceiptNonce: pr.CacheReceiptNonce,
		ModelID: "model", ModelAggregateHash: capability.ModelAggregateHash,
		PromptContractID: capability.PromptContractID, CacheEpoch: capability.CacheEpoch,
		CacheSeq: 2, Outcome: "ready", Tier: "ssd",
		ReadyAnchors:               []protocol.PrefixCacheAnchor{prompt, final},
		ExpectedPrefillTokensSaved: final.TokenCount, StageMs: 2,
	}
	if !r.ApplyPrefixCacheReadyV2(provider.ID, ready) {
		t.Fatal("durable ready proof was rejected")
	}
	if holders, _ := r.CacheRoutingStateCounts(); holders == 0 {
		t.Fatal("test setup did not create exact routing evidence")
	}

	restarted, restartedProvider, restartedCapability := exactTestRegistry(t)
	if holders, attempts := restarted.CacheRoutingStateCounts(); holders != 0 || attempts != 0 {
		t.Fatalf("fresh coordinator restored ephemeral cache state: holders=%d attempts=%d", holders, attempts)
	}
	future := exactTestPlan(exactTestAnchor(1, "b"), prompt, final)
	hints := restarted.cacheRouting.hints(
		future,
		map[string]cacheRoutingCapability{
			restartedProvider.ID: {
				Provider: restartedProvider, Capability: restartedCapability,
			},
		},
		restarted.cacheRouteKeys.route,
		CacheRoutingOn,
		time.Now(),
	)
	if len(hints) != 0 {
		t.Fatalf("fresh coordinator reused pre-restart holders: %+v", hints)
	}
}

func TestExactV2SpeculativeAttemptsKeepWinnerAndLoserProofsIsolated(t *testing.T) {
	r, providerA, capabilityA := exactTestRegistry(t)
	capabilityB := exactTestCapability("22222222-2222-2222-2222-222222222222")
	providerB := &Provider{
		ID:                  "provider-b",
		PrefixCacheProtocol: 2,
		PrefixCacheV2Models: map[string]protocol.PrefixCacheV2Capability{
			"model": capabilityB,
		},
	}
	r.mu.Lock()
	r.providers[providerB.ID] = providerB
	r.mu.Unlock()

	prompt := exactTestAnchor(2, "c")
	final := exactTestAnchor(3, "d")
	plan := exactTestPlan(exactTestAnchor(1, "b"), prompt)
	attemptA := &PendingRequest{RequestID: "speculative-request", Model: "model", CachePlan: plan}
	attemptB := &PendingRequest{RequestID: "speculative-request", Model: "model", CachePlan: plan}
	if err := r.PrepareCacheAttempt(attemptA, providerA); err != nil {
		t.Fatal(err)
	}
	if err := r.PrepareCacheAttempt(attemptB, providerB); err != nil {
		t.Fatal(err)
	}
	if attemptA.CacheReceiptNonce == attemptB.CacheReceiptNonce {
		t.Fatal("speculative attempts shared a receipt nonce")
	}

	lookupB := &protocol.PrefixCacheLookupV2Message{
		RequestID: attemptB.RequestID, CacheReceiptNonce: attemptB.CacheReceiptNonce,
		ModelID: "model", ModelAggregateHash: capabilityB.ModelAggregateHash,
		PromptContractID: capabilityB.PromptContractID, CacheEpoch: capabilityB.CacheEpoch,
		CacheSeq: 1, PromptAnchor: prompt, Outcome: "miss_absent", Tier: "ssd", StageMs: 1,
	}
	spoofed := *lookupB
	spoofed.CacheReceiptNonce = attemptA.CacheReceiptNonce
	if r.ApplyPrefixCacheLookupV2(providerB.ID, &spoofed) {
		t.Fatal("backup provider claimed the primary attempt nonce")
	}
	if !r.ApplyPrefixCacheLookupV2(providerB.ID, lookupB) {
		t.Fatal("valid winner lookup proof was rejected")
	}
	readyB := &protocol.PrefixCacheReadyV2Message{
		RequestID: attemptB.RequestID, CacheReceiptNonce: attemptB.CacheReceiptNonce,
		ModelID: "model", ModelAggregateHash: capabilityB.ModelAggregateHash,
		PromptContractID: capabilityB.PromptContractID, CacheEpoch: capabilityB.CacheEpoch,
		CacheSeq: 2, Outcome: "ready", Tier: "ssd",
		ReadyAnchors:               []protocol.PrefixCacheAnchor{prompt, final},
		ExpectedPrefillTokensSaved: final.TokenCount, StageMs: 2,
	}
	if !r.ApplyPrefixCacheReadyV2(providerB.ID, readyB) {
		t.Fatal("valid winner ready proof was rejected")
	}

	loserNonce := attemptA.CacheReceiptNonce
	r.ForgetCacheAttempt(attemptA)
	lateLoser := &protocol.PrefixCacheLookupV2Message{
		RequestID: attemptA.RequestID, CacheReceiptNonce: loserNonce,
		ModelID: "model", ModelAggregateHash: capabilityA.ModelAggregateHash,
		PromptContractID: capabilityA.PromptContractID, CacheEpoch: capabilityA.CacheEpoch,
		CacheSeq: 1, PromptAnchor: prompt, Outcome: "miss_absent", Tier: "ssd", StageMs: 1,
	}
	if r.ApplyPrefixCacheLookupV2(providerA.ID, lateLoser) {
		t.Fatal("accepted a late proof from the forgotten speculative loser")
	}

	future := exactTestPlan(exactTestAnchor(1, "b"), prompt, final)
	hints := r.cacheRouting.hints(
		future,
		map[string]cacheRoutingCapability{
			providerA.ID: {Provider: providerA, Capability: capabilityA},
			providerB.ID: {Provider: providerB, Capability: capabilityB},
		},
		r.cacheRouteKeys.route,
		CacheRoutingOn,
		time.Now(),
	)
	if _, ok := hints[providerA.ID]; ok {
		t.Fatal("forgotten speculative loser retained ownership")
	}
	if hint, ok := hints[providerB.ID]; !ok || hint.CachedTokens != final.TokenCount {
		t.Fatalf("winner ownership = %+v, present=%t", hint, ok)
	}
}

func TestExactV2ProofMismatchQuarantinesOnlyCurrentCapability(t *testing.T) {
	r, provider, capability := exactTestRegistry(t)
	prompt := exactTestAnchor(1, "c")
	pr := &PendingRequest{
		RequestID: "request-mismatch",
		Model:     "model",
		CachePlan: exactTestPlan(prompt),
	}
	if err := r.PrepareCacheAttempt(pr, provider); err != nil {
		t.Fatal(err)
	}
	mismatch := &protocol.PrefixCacheLookupV2Message{
		RequestID: pr.RequestID, CacheReceiptNonce: pr.CacheReceiptNonce,
		ModelID: "model", ModelAggregateHash: capability.ModelAggregateHash,
		PromptContractID: capability.PromptContractID, CacheEpoch: capability.CacheEpoch,
		CacheSeq: 1, PromptAnchor: exactTestAnchor(1, "d"),
		Outcome: "miss_absent", Tier: "ssd", StageMs: 1,
	}
	if r.ApplyPrefixCacheLookupV2(provider.ID, mismatch) {
		t.Fatal("accepted mismatched provider token proof")
	}
	if _, ok := r.currentPrefixCacheV2Capability(provider.ID, "model"); ok {
		t.Fatal("mismatched capability remained routing-eligible")
	}

	rotated := capability
	rotated.CacheEpoch = "22222222-2222-2222-2222-222222222222"
	provider.mu.Lock()
	provider.PrefixCacheV2Models["model"] = rotated
	provider.mu.Unlock()
	if got, ok := r.currentPrefixCacheV2Capability(provider.ID, "model"); !ok || got != rotated {
		t.Fatalf("new epoch did not clear quarantine: got=%+v ok=%t", got, ok)
	}
}

func TestExactV2IdentityMismatchQuarantinesCurrentCapability(t *testing.T) {
	r, provider, capability := exactTestRegistry(t)
	prompt := exactTestAnchor(1, "c")
	pr := &PendingRequest{
		RequestID: "request-identity-mismatch",
		Model:     "model",
		CachePlan: exactTestPlan(prompt),
	}
	if err := r.PrepareCacheAttempt(pr, provider); err != nil {
		t.Fatal(err)
	}
	mismatch := &protocol.PrefixCacheLookupV2Message{
		RequestID: pr.RequestID, CacheReceiptNonce: pr.CacheReceiptNonce,
		ModelID: "model", ModelAggregateHash: strings.Repeat("f", 64),
		PromptContractID: capability.PromptContractID, CacheEpoch: capability.CacheEpoch,
		CacheSeq: 1, PromptAnchor: prompt,
		Outcome: "miss_absent", Tier: "ssd", StageMs: 1,
	}
	if r.ApplyPrefixCacheLookupV2(provider.ID, mismatch) {
		t.Fatal("accepted a proof for the wrong model build")
	}
	if _, ok := r.currentPrefixCacheV2Capability(provider.ID, "model"); ok {
		t.Fatal("identity-mismatched capability remained routing-eligible")
	}
}

func TestExactRoutingV1ProviderRemainsColdBaseline(t *testing.T) {
	r, provider, _ := exactTestRegistry(t)
	provider.mu.Lock()
	provider.PrefixCacheProtocol = 1
	provider.PrefixCacheV2Models = nil
	provider.mu.Unlock()
	pr := &PendingRequest{
		RequestID: "v1-baseline",
		Model:     "model",
		CachePlan: exactTestPlan(exactTestAnchor(1, "c")),
	}
	if err := r.PrepareCacheAttempt(pr, provider); err != nil {
		t.Fatal(err)
	}
	if pr.CacheReceiptNonce != "" || pr.CacheScope != "" ||
		pr.PrefixCacheProtocol != 0 || pr.CacheRoutingParticipates() {
		t.Fatalf("v1 provider received active routing metadata: %+v", pr)
	}
	if r.ApplyPrefixCacheLookup(provider.ID, &protocol.PrefixCacheLookupMessage{}) ||
		r.ApplyPrefixCacheReady(provider.ID, &protocol.PrefixCacheReadyMessage{}) {
		t.Fatal("v1 receipt mutated exact routing evidence")
	}
}

func TestExactV2LongestHolderChangesMultiProviderSelection(t *testing.T) {
	r, _, capability := exactTestRegistry(t)
	r.mu.Lock()
	delete(r.providers, "provider-a")
	r.mu.Unlock()
	cached := makeSchedulerProvider(t, r, "cached", "model", 100)
	cold := makeSchedulerProvider(t, r, "cold", "model", 100)
	for _, provider := range []*Provider{cached, cold} {
		provider.mu.Lock()
		provider.PrefillTPS = 100
		provider.PrefixCacheProtocol = 2
		provider.PrefixCacheV2Models =
			map[string]protocol.PrefixCacheV2Capability{"model": capability}
		provider.BackendCapacity.Slots[0].ObservedPrefillTPS = 100
		provider.mu.Unlock()
	}

	a1 := exactTestAnchor(1, "c")
	a2 := exactTestAnchor(2, "d")
	a3 := exactTestAnchor(3, "e")
	a4 := exactTestAnchor(4, "f")
	pr := &PendingRequest{
		RequestID: "seed-holder", Model: "model", CachePlan: exactTestPlan(a1, a2),
	}
	if err := r.PrepareCacheAttempt(pr, cached); err != nil {
		t.Fatal(err)
	}
	if !r.ApplyPrefixCacheLookupV2(cached.ID, &protocol.PrefixCacheLookupV2Message{
		RequestID: pr.RequestID, CacheReceiptNonce: pr.CacheReceiptNonce,
		ModelID: "model", ModelAggregateHash: capability.ModelAggregateHash,
		PromptContractID: capability.PromptContractID, CacheEpoch: capability.CacheEpoch,
		CacheSeq: 1, PromptAnchor: a2, Outcome: "miss_absent", Tier: "ssd", StageMs: 1,
	}) {
		t.Fatal("seed lookup failed")
	}
	if !r.ApplyPrefixCacheReadyV2(cached.ID, &protocol.PrefixCacheReadyV2Message{
		RequestID: pr.RequestID, CacheReceiptNonce: pr.CacheReceiptNonce,
		ModelID: "model", ModelAggregateHash: capability.ModelAggregateHash,
		PromptContractID: capability.PromptContractID, CacheEpoch: capability.CacheEpoch,
		CacheSeq: 2, Outcome: "ready", Tier: "ssd",
		ReadyAnchors:               []protocol.PrefixCacheAnchor{a2, a3},
		ExpectedPrefillTokensSaved: a3.TokenCount,
		StageMs:                    1,
	}) {
		t.Fatal("seed ready failed")
	}

	next := &PendingRequest{
		RequestID:             "route-with-holder",
		Model:                 "model",
		EstimatedPromptTokens: a4.TokenCount,
		RequestedMaxTokens:    128,
		CachePlan:             exactTestPlan(a1, a2, a3, a4),
	}
	selected, decision := r.ReserveProviderEx("model", next)
	if selected == nil {
		t.Fatalf("routing failed: %+v", decision)
	}
	if selected.ID != cached.ID || decision.CacheDiscountMs <= 0 ||
		next.CacheSelectionMode != "active" || !next.CacheSelectionSelected {
		t.Fatalf("exact holder did not win: provider=%s decision=%+v request=%+v",
			selected.ID, decision, next)
	}
	selected.RemovePending(next.RequestID)
	r.SetProviderIdle(selected.ID)
	cached.mu.Lock()
	cached.BackendCapacity.Slots[0].NumWaiting = 10
	cached.mu.Unlock()
	busy := &PendingRequest{
		RequestID:             "route-busy-holder",
		Model:                 "model",
		EstimatedPromptTokens: a4.TokenCount,
		RequestedMaxTokens:    128,
		CachePlan:             exactTestPlan(a1, a2, a3, a4),
	}
	selected, decision = r.ReserveProviderEx("model", busy)
	if selected == nil || selected.ID != cold.ID {
		t.Fatalf("busy holder overrode normal load cost: provider=%v decision=%+v",
			selected, decision)
	}
}

func TestExactRoutingDisabledV2CapabilityRemainsColdBaseline(t *testing.T) {
	r, provider, capability := exactTestRegistry(t)
	capability.Ready = false
	provider.mu.Lock()
	provider.PrefixCacheV2Models["model"] = capability
	provider.mu.Unlock()

	plan := exactTestPlan(exactTestAnchor(1, "c"))
	pr := &PendingRequest{RequestID: "disabled-v2", Model: "model", CachePlan: plan}
	if err := r.PrepareCacheAttempt(pr, provider); err != nil {
		t.Fatal(err)
	}
	if pr.CacheReceiptNonce != "" || pr.CacheRoutingParticipates() {
		t.Fatal("disabled v2 capability was allowed to participate")
	}
}

func TestExactRoutingTrackerRemainsBoundedUnderConcurrency(t *testing.T) {
	tracker := newCacheRoutingTracker(time.Minute, 2)
	tracker.maxEntries = 128
	tracker.maxAttempts = 256
	now := time.Now()
	var workers sync.WaitGroup
	for worker := 0; worker < 16; worker++ {
		workers.Add(1)
		go func(worker int) {
			defer workers.Done()
			for index := 0; index < 200; index++ {
				key := fmt.Sprintf("key-%d-%d", worker, index)
				nonce := fmt.Sprintf("nonce-%d-%d", worker, index)
				tracker.mu.Lock()
				tracker.upsertHolderLocked(key, cacheHolder{
					ProviderID: fmt.Sprintf("provider-%d", worker),
					UpdatedAt:  now,
					ExpiresAt:  now.Add(time.Minute),
				})
				tracker.storeAttemptLocked(nonce, cacheAttempt{
					RequestID:  fmt.Sprintf("request-%d-%d", worker, index),
					ProviderID: fmt.Sprintf("provider-%d", worker),
					CreatedAt:  now.Add(time.Duration(worker*200+index) * time.Nanosecond),
					ExpiresAt:  now.Add(time.Minute),
				})
				tracker.enforceAttemptCapLocked()
				tracker.mu.Unlock()
			}
		}(worker)
	}
	workers.Wait()
	tracker.mu.Lock()
	defer tracker.mu.Unlock()
	if tracker.holderCount > tracker.maxEntries ||
		len(tracker.holders) > tracker.maxEntries ||
		len(tracker.attempts) > tracker.maxAttempts ||
		len(tracker.holderOrder) != tracker.holderCount ||
		len(tracker.attemptOrder) != len(tracker.attempts) {
		t.Fatalf(
			"tracker exceeded bounds: holders=%d keys=%d holder_heap=%d attempts=%d attempt_heap=%d",
			tracker.holderCount,
			len(tracker.holders),
			len(tracker.holderOrder),
			len(tracker.attempts),
			len(tracker.attemptOrder),
		)
	}
}

func TestExactRoutingExpiryAndDisconnectRemoveConnectionEvidence(t *testing.T) {
	r, provider, capability := exactTestRegistry(t)
	anchor := exactTestAnchor(1, "c")
	plan := exactTestPlan(anchor)
	key := cacheBoundaryKey(r.cacheRouteKeys.route, plan, capability.CacheEpoch, anchor)
	now := time.Now()
	r.cacheRouting.mu.Lock()
	r.cacheRouting.upsertHolderLocked(key, cacheHolder{
		ProviderID:         provider.ID,
		Provider:           provider,
		ModelID:            "model",
		ModelAggregateHash: capability.ModelAggregateHash,
		PromptContractID:   capability.PromptContractID,
		CacheEpoch:         capability.CacheEpoch,
		Anchor:             anchor,
		StageMs:            1,
		UpdatedAt:          now,
		ExpiresAt:          now.Add(time.Second),
	})
	r.cacheRouting.mu.Unlock()
	capabilities := map[string]cacheRoutingCapability{
		provider.ID: {Provider: provider, Capability: capability},
	}
	if len(r.cacheRouting.hints(
		plan, capabilities, r.cacheRouteKeys.route, CacheRoutingOn, now)) != 1 {
		t.Fatal("fresh holder was unavailable")
	}
	if len(r.cacheRouting.hints(
		plan, capabilities, r.cacheRouteKeys.route, CacheRoutingOn, now.Add(2*time.Second))) != 0 {
		t.Fatal("expired holder remained available")
	}

	r.cacheRouting.mu.Lock()
	r.cacheRouting.upsertHolderLocked(key, cacheHolder{
		ProviderID: provider.ID, Provider: provider, ModelID: "model",
		ModelAggregateHash: capability.ModelAggregateHash,
		PromptContractID:   capability.PromptContractID,
		CacheEpoch:         capability.CacheEpoch, Anchor: anchor,
		StageMs:   1,
		UpdatedAt: now, ExpiresAt: now.Add(time.Minute),
	})
	r.cacheRouting.mu.Unlock()
	r.cacheRouting.disconnect(provider.ID)
	if len(r.cacheRouting.hints(
		plan, capabilities, r.cacheRouteKeys.route, CacheRoutingOn, now)) != 0 {
		t.Fatal("disconnect left connection-scoped holder evidence")
	}
}
