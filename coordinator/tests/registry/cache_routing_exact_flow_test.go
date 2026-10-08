package registry_test

import (
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachetracker"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	. "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestExactRoutingHintRevalidatesCapabilityBeforeDiscount(t *testing.T) {
	r, provider, capability := newExactRoutingFixture(t)
	provider.Mu().Lock()
	provider.Models = []protocol.ModelInfo{{
		ID: "model", WeightHash: capability.ModelAggregateHash,
	}}
	provider.Mu().Unlock()
	anchor := exactTestAnchor(1, "c")
	plan := boundTestCachePlan(r, exactTestPlan(anchor))
	now := time.Now()
	holder := cachetracker.Holder[*Provider]{
		ProviderID: provider.ID, Provider: provider, ModelID: "model",
		ModelAggregateHash: capability.ModelAggregateHash, PromptContractID: capability.PromptContractID,
		CacheEpoch: capability.CacheEpoch, Anchor: anchor, StageMs: 1,
		UpdatedAt: now, ExpiresAt: now.Add(time.Minute),
	}
	r.tracker.UpsertHolderLocked(plan.BoundaryKey(r.routeKey, anchor), holder)
	hints, _ := r.query.Query("model", plan, r.routeKey, CacheRoutingOn, now)
	hint := hints[provider.ID]
	if !exactHintCurrent(hint, provider) {
		t.Fatal("fresh exact hint was rejected")
	}

	rotated := capability
	rotated.CacheEpoch = "22222222-2222-2222-2222-222222222222"
	if err := r.UpdatePrefixCacheCapabilities(
		provider.ID, 2, []protocol.PrefixCacheV2Capability{rotated}); err != nil {
		t.Fatal(err)
	}
	if exactHintCurrent(hint, provider) {
		t.Fatal("pre-heartbeat hint survived a capability epoch rotation")
	}

	holder.CacheEpoch = rotated.CacheEpoch
	r.tracker.UpsertHolderLocked(plan.BoundaryKey(r.routeKey, anchor), holder)
	hints, _ = r.query.Query("model", plan, r.routeKey, CacheRoutingOn, now)
	rotatedHint := hints[provider.ID]
	if !exactHintCurrent(rotatedHint, provider) {
		t.Fatal("rotated capability did not admit a fresh hint")
	}
	pr := &PendingRequest{RequestID: "hint-quarantine", Model: "model", CachePlan: plan}
	if err := r.PrepareCacheAttempt(pr, provider); err != nil {
		t.Fatal(err)
	}
	if r.ApplyPrefixCacheLookupV2(provider.ID, &protocol.PrefixCacheLookupV2Message{
		RequestID: pr.RequestID, CacheReceiptNonce: preparedTestCacheMetadata(pr).CacheReceiptNonce,
		ModelID: "model", ModelAggregateHash: rotated.ModelAggregateHash,
		PromptContractID: rotated.PromptContractID, CacheEpoch: rotated.CacheEpoch,
		CacheSeq: 1, PromptAnchor: exactTestAnchor(1, "d"), Outcome: "miss_absent", Tier: "ssd", StageMs: 1,
	}) {
		t.Fatal("mismatched proof was accepted")
	}
	if exactHintCurrent(rotatedHint, provider) {
		t.Fatal("pre-quarantine hint survived a proof failure")
	}
	if !r.config.Proofs.Rejected(cachetracker.FenceKey{ProviderID: provider.ID, ModelID: "model", Tier: "ssd"}, rotated, time.Now()) {
		t.Fatal("proof failure did not quarantine the advertised capability")
	}
}

func TestExactV2ReadyCreatesLongestPrefixHolderAndMissInvalidates(t *testing.T) {
	r, provider, capability := newExactRoutingFixture(t)
	a1 := exactTestAnchor(1, "c")
	a2 := exactTestAnchor(2, "d")
	a3 := exactTestAnchor(3, "e")
	a4 := exactTestAnchor(4, "f")
	initial := exactTestPlan(a1, a2)
	pr := &PendingRequest{RequestID: "request-1", Model: "model", CachePlan: initial}
	if err := prepareBoundTestCacheAttempt(r, pr, provider); err != nil {
		t.Fatal(err)
	}
	if preparedTestCacheMetadata(pr).CacheReceiptNonce == "" || !pr.CacheRoutingParticipates() {
		t.Fatal("protocol-v2 attempt was not activated")
	}
	lookup := &protocol.PrefixCacheLookupV2Message{
		RequestID: pr.RequestID, CacheReceiptNonce: preparedTestCacheMetadata(pr).CacheReceiptNonce,
		ModelID: "model", ModelAggregateHash: capability.ModelAggregateHash,
		PromptContractID: capability.PromptContractID, CacheEpoch: capability.CacheEpoch,
		CacheSeq: 1, PromptAnchor: a2, Outcome: "miss_absent", Tier: "ssd", StageMs: 1,
	}
	if !r.ApplyPrefixCacheLookupV2(provider.ID, lookup) {
		t.Fatal("valid lookup proof was rejected")
	}
	ready := &protocol.PrefixCacheReadyV2Message{
		RequestID: pr.RequestID, CacheReceiptNonce: preparedTestCacheMetadata(pr).CacheReceiptNonce,
		ModelID: "model", ModelAggregateHash: capability.ModelAggregateHash,
		PromptContractID: capability.PromptContractID, CacheEpoch: capability.CacheEpoch,
		CacheSeq: 2, Outcome: "ready", Tier: "ssd", ReadyAnchors: []protocol.PrefixCacheAnchor{a2, a3},
		ExpectedPrefillTokensSaved: a3.TokenCount, StageMs: 2,
	}
	if !r.ApplyPrefixCacheReadyV2(provider.ID, ready) {
		t.Fatal("durable ready proof was rejected")
	}

	future := exactTestPlan(a1, a2, a3, a4)
	hints := r.hints(
		future,
		map[string]CacheRoutingCapability{
			provider.ID: {Provider: provider, Capability: capability},
		},
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
		if hints := r.hints(
			variant.plan,
			map[string]CacheRoutingCapability{
				provider.ID: {Provider: provider, Capability: variant.capability},
			},
			time.Now(),
		); len(hints) != 0 {
			t.Fatalf("%s crossed exact routing isolation: %+v", name, hints)
		}
	}

	missPR := &PendingRequest{RequestID: "request-2", Model: "model", CachePlan: future}
	if err := prepareBoundTestCacheAttempt(r, missPR, provider); err != nil {
		t.Fatal(err)
	}
	miss := &protocol.PrefixCacheLookupV2Message{
		RequestID: missPR.RequestID, CacheReceiptNonce: preparedTestCacheMetadata(missPR).CacheReceiptNonce,
		ModelID: "model", ModelAggregateHash: capability.ModelAggregateHash,
		PromptContractID: capability.PromptContractID, CacheEpoch: capability.CacheEpoch,
		CacheSeq: 3, PromptAnchor: a4, Outcome: "miss_absent", Tier: "ssd", StageMs: 1,
	}
	if !r.ApplyPrefixCacheLookupV2(provider.ID, miss) {
		t.Fatal("valid miss proof was rejected")
	}
	if hints := r.hints(
		future,
		map[string]CacheRoutingCapability{
			provider.ID: {Provider: provider, Capability: capability},
		},
		time.Now(),
	); len(hints) != 0 {
		t.Fatalf("miss left stale exact holders: %+v", hints)
	}
	lifecycle := r.CacheRoutingLifecycleStatus()
	if lifecycle.HolderAdded != 2 ||
		lifecycle.HolderRemoved[string(cachetracker.RemovalMissInvalidation)] != 2 {
		t.Fatalf("miss lifecycle counters = %+v", lifecycle)
	}
}

func TestExactV2CoordinatorRestartDropsEphemeralRoutingState(t *testing.T) {
	r, provider, capability := newExactRoutingFixture(t)
	prompt := exactTestAnchor(2, "c")
	final := exactTestAnchor(3, "d")
	plan := exactTestPlan(exactTestAnchor(1, "b"), prompt)
	pr := &PendingRequest{RequestID: "request-before-restart", Model: "model", CachePlan: plan}
	if err := prepareBoundTestCacheAttempt(r, pr, provider); err != nil {
		t.Fatal(err)
	}
	lookup := &protocol.PrefixCacheLookupV2Message{
		RequestID: pr.RequestID, CacheReceiptNonce: preparedTestCacheMetadata(pr).CacheReceiptNonce,
		ModelID: "model", ModelAggregateHash: capability.ModelAggregateHash,
		PromptContractID: capability.PromptContractID, CacheEpoch: capability.CacheEpoch,
		CacheSeq: 1, PromptAnchor: prompt, Outcome: "miss_absent", Tier: "ssd", StageMs: 1,
	}
	if !r.ApplyPrefixCacheLookupV2(provider.ID, lookup) {
		t.Fatal("valid lookup proof was rejected")
	}
	ready := &protocol.PrefixCacheReadyV2Message{
		RequestID: pr.RequestID, CacheReceiptNonce: preparedTestCacheMetadata(pr).CacheReceiptNonce,
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

	restarted, restartedProvider, restartedCapability := newExactRoutingFixture(t)
	if holders, attempts := restarted.CacheRoutingStateCounts(); holders != 0 || attempts != 0 {
		t.Fatalf("fresh coordinator restored ephemeral cache state: holders=%d attempts=%d", holders, attempts)
	}
	future := exactTestPlan(exactTestAnchor(1, "b"), prompt, final)
	hints := restarted.hints(
		future,
		map[string]CacheRoutingCapability{
			restartedProvider.ID: {
				Provider: restartedProvider, Capability: restartedCapability,
			},
		},
		time.Now(),
	)
	if len(hints) != 0 {
		t.Fatalf("fresh coordinator reused pre-restart holders: %+v", hints)
	}
}

func TestExactV2SpeculativeAttemptsKeepWinnerAndLoserProofsIsolated(t *testing.T) {
	r, providerA, capabilityA := newExactRoutingFixture(t)
	capabilityB := exactTestCapability("22222222-2222-2222-2222-222222222222")
	providerB := r.Register("provider-b", nil, &protocol.RegisterMessage{
		PrefixCacheProtocol: 2,
		PrefixCacheV2Models: []protocol.PrefixCacheV2Capability{capabilityB},
	})

	prompt := exactTestAnchor(2, "c")
	final := exactTestAnchor(3, "d")
	plan := exactTestPlan(exactTestAnchor(1, "b"), prompt)
	attemptA := &PendingRequest{RequestID: "speculative-request", Model: "model", CachePlan: plan}
	attemptB := &PendingRequest{RequestID: "speculative-request", Model: "model", CachePlan: plan}
	if err := prepareBoundTestCacheAttempt(r, attemptA, providerA); err != nil {
		t.Fatal(err)
	}
	if err := prepareBoundTestCacheAttempt(r, attemptB, providerB); err != nil {
		t.Fatal(err)
	}
	if preparedTestCacheMetadata(attemptA).CacheReceiptNonce == preparedTestCacheMetadata(attemptB).CacheReceiptNonce {
		t.Fatal("speculative attempts shared a receipt nonce")
	}

	lookupB := &protocol.PrefixCacheLookupV2Message{
		RequestID: attemptB.RequestID, CacheReceiptNonce: preparedTestCacheMetadata(attemptB).CacheReceiptNonce,
		ModelID: "model", ModelAggregateHash: capabilityB.ModelAggregateHash,
		PromptContractID: capabilityB.PromptContractID, CacheEpoch: capabilityB.CacheEpoch,
		CacheSeq: 1, PromptAnchor: prompt, Outcome: "miss_absent", Tier: "ssd", StageMs: 1,
	}
	spoofed := *lookupB
	spoofed.CacheReceiptNonce = preparedTestCacheMetadata(attemptA).CacheReceiptNonce
	if r.ApplyPrefixCacheLookupV2(providerB.ID, &spoofed) {
		t.Fatal("backup provider claimed the primary attempt nonce")
	}
	if !r.ApplyPrefixCacheLookupV2(providerB.ID, lookupB) {
		t.Fatal("valid winner lookup proof was rejected")
	}
	readyB := &protocol.PrefixCacheReadyV2Message{
		RequestID: attemptB.RequestID, CacheReceiptNonce: preparedTestCacheMetadata(attemptB).CacheReceiptNonce,
		ModelID: "model", ModelAggregateHash: capabilityB.ModelAggregateHash,
		PromptContractID: capabilityB.PromptContractID, CacheEpoch: capabilityB.CacheEpoch,
		CacheSeq: 2, Outcome: "ready", Tier: "ssd",
		ReadyAnchors:               []protocol.PrefixCacheAnchor{prompt, final},
		ExpectedPrefillTokensSaved: final.TokenCount, StageMs: 2,
	}
	if !r.ApplyPrefixCacheReadyV2(providerB.ID, readyB) {
		t.Fatal("valid winner ready proof was rejected")
	}

	loserNonce := preparedTestCacheMetadata(attemptA).CacheReceiptNonce
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
	hints := r.hints(
		future,
		map[string]CacheRoutingCapability{
			providerA.ID: {Provider: providerA, Capability: capabilityA},
			providerB.ID: {Provider: providerB, Capability: capabilityB},
		},
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
	r, provider, capability := newExactRoutingFixture(t)
	prompt := exactTestAnchor(1, "c")
	pr := &PendingRequest{
		RequestID: "request-mismatch",
		Model:     "model",
		CachePlan: exactTestPlan(prompt),
	}
	if err := prepareBoundTestCacheAttempt(r, pr, provider); err != nil {
		t.Fatal(err)
	}
	mismatch := &protocol.PrefixCacheLookupV2Message{
		RequestID: pr.RequestID, CacheReceiptNonce: preparedTestCacheMetadata(pr).CacheReceiptNonce,
		ModelID: "model", ModelAggregateHash: capability.ModelAggregateHash,
		PromptContractID: capability.PromptContractID, CacheEpoch: capability.CacheEpoch,
		CacheSeq: 1, PromptAnchor: exactTestAnchor(1, "d"),
		Outcome: "miss_absent", Tier: "ssd", StageMs: 1,
	}
	if r.ApplyPrefixCacheLookupV2(provider.ID, mismatch) {
		t.Fatal("accepted mismatched provider token proof")
	}
	if _, reason := r.admission.Admit(provider.ID, "model", "ssd"); reason == CacheReceiptAccepted {
		t.Fatal("mismatched capability remained routing-eligible")
	}

	rotated := capability
	rotated.CacheEpoch = "22222222-2222-2222-2222-222222222222"
	provider.Mu().Lock()
	provider.PrefixCacheV2Models["model"] = rotated
	provider.Mu().Unlock()
	if got, reason := r.admission.Admit(provider.ID, "model", "ssd"); reason != CacheReceiptAccepted || got != rotated {
		t.Fatalf("new epoch did not clear quarantine: got=%+v ok=%t", got, reason == CacheReceiptAccepted)
	}
}

func TestExactV2IdentityMismatchQuarantinesCurrentCapability(t *testing.T) {
	r, provider, capability := newExactRoutingFixture(t)
	prompt := exactTestAnchor(1, "c")
	pr := &PendingRequest{
		RequestID: "request-identity-mismatch",
		Model:     "model",
		CachePlan: exactTestPlan(prompt),
	}
	if err := prepareBoundTestCacheAttempt(r, pr, provider); err != nil {
		t.Fatal(err)
	}
	mismatch := &protocol.PrefixCacheLookupV2Message{
		RequestID: pr.RequestID, CacheReceiptNonce: preparedTestCacheMetadata(pr).CacheReceiptNonce,
		ModelID: "model", ModelAggregateHash: strings.Repeat("f", 64),
		PromptContractID: capability.PromptContractID, CacheEpoch: capability.CacheEpoch,
		CacheSeq: 1, PromptAnchor: prompt,
		Outcome: "miss_absent", Tier: "ssd", StageMs: 1,
	}
	if r.ApplyPrefixCacheLookupV2(provider.ID, mismatch) {
		t.Fatal("accepted a proof for the wrong model build")
	}
	if _, reason := r.admission.Admit(provider.ID, "model", "ssd"); reason == CacheReceiptAccepted {
		t.Fatal("identity-mismatched capability remained routing-eligible")
	}
}

func TestExactRoutingV1ProviderRemainsColdBaseline(t *testing.T) {
	r, provider, _ := newExactRoutingFixture(t)
	provider.Mu().Lock()
	provider.PrefixCacheProtocol = 1
	provider.PrefixCacheV2Models = nil
	provider.Mu().Unlock()
	pr := &PendingRequest{
		RequestID: "v1-baseline",
		Model:     "model",
		CachePlan: exactTestPlan(exactTestAnchor(1, "c")),
	}
	if err := prepareBoundTestCacheAttempt(r, pr, provider); err != nil {
		t.Fatal(err)
	}
	if preparedTestCacheMetadata(pr).CacheReceiptNonce != "" || preparedTestCacheMetadata(pr).CacheScope != "" ||
		preparedTestCacheMetadata(pr).PrefixCacheProtocol != 0 || pr.CacheRoutingParticipates() {
		t.Fatalf("v1 provider received active routing metadata: %+v", pr)
	}
	if r.ApplyPrefixCacheLookup(provider.ID, &protocol.PrefixCacheLookupMessage{}) ||
		r.ApplyPrefixCacheReady(provider.ID, &protocol.PrefixCacheReadyMessage{}) {
		t.Fatal("v1 receipt mutated exact routing evidence")
	}
}

func TestExactRoutingMixedV1V2FleetFallsBackToV1Inference(t *testing.T) {
	r, original, capability := newExactRoutingFixture(t)
	r.Disconnect(original.ID)
	v1 := makeSchedulerProvider(t, r.Registry, "mixed-v1", "model", 100)
	v2 := makeSchedulerProvider(t, r.Registry, "mixed-v2", "model", 100)
	v1.Mu().Lock()
	v1.PrefixCacheProtocol = 1
	v1.Mu().Unlock()
	v2.Mu().Lock()
	v2.PrefixCacheProtocol = 2
	v2.Models[0].WeightHash = capability.ModelAggregateHash
	v2.PrefixCacheV2Models = map[string]protocol.PrefixCacheV2Capability{"model": capability}
	// Keep the cache-capable provider routable but more expensive. The ordinary
	// v1 provider must remain a valid cold fallback instead of failing closed.
	v2.BackendCapacity.Slots[0].NumWaiting = 10
	v2.Mu().Unlock()

	request := &PendingRequest{
		RequestID: "mixed-fallback", Model: "model",
		EstimatedPromptTokens: 512, RequestedMaxTokens: 128,
		CachePlan: exactTestPlan(exactTestAnchor(1, "d")),
	}
	selected, decision := r.ReserveProviderEx("model", request)
	if selected == nil || selected.ID != v1.ID {
		t.Fatalf("mixed fleet did not fall back to v1: provider=%v decision=%+v", selected, decision)
	}
	if err := prepareBoundTestCacheAttempt(r, request, selected); err != nil {
		t.Fatal(err)
	}
	if preparedTestCacheMetadata(request).CacheReceiptNonce != "" || preparedTestCacheMetadata(request).CacheScope != "" ||
		preparedTestCacheMetadata(request).PrefixCacheProtocol != 0 || request.CacheRoutingParticipates() {
		t.Fatalf("v1 fallback received exact-cache metadata: %+v", request)
	}
}

func TestExactRoutingAccountsMissDonationHitLifecycle(t *testing.T) {
	r, provider, capability := newExactRoutingFixture(t)
	a1 := exactTestAnchor(1, "a")
	a2 := exactTestAnchor(2, "b")
	a3 := exactTestAnchor(3, "c")

	miss := &PendingRequest{
		RequestID: "lifecycle-miss", Model: "model", CachePlan: exactTestPlan(a1, a2),
	}
	if err := prepareBoundTestCacheAttempt(r, miss, provider); err != nil {
		t.Fatal(err)
	}
	if !r.ApplyPrefixCacheLookupV2(provider.ID, &protocol.PrefixCacheLookupV2Message{
		RequestID: miss.RequestID, CacheReceiptNonce: preparedTestCacheMetadata(miss).CacheReceiptNonce,
		ModelID: "model", ModelAggregateHash: capability.ModelAggregateHash,
		PromptContractID: capability.PromptContractID, CacheEpoch: capability.CacheEpoch,
		CacheSeq: 1, PromptAnchor: a2, Outcome: "miss_absent", Tier: "ssd", StageMs: 1,
	}) {
		t.Fatal("miss receipt rejected")
	}
	if !r.ApplyPrefixCacheReadyV2(provider.ID, &protocol.PrefixCacheReadyV2Message{
		RequestID: miss.RequestID, CacheReceiptNonce: preparedTestCacheMetadata(miss).CacheReceiptNonce,
		ModelID: "model", ModelAggregateHash: capability.ModelAggregateHash,
		PromptContractID: capability.PromptContractID, CacheEpoch: capability.CacheEpoch,
		CacheSeq: 2, Outcome: "ready", Tier: "ssd",
		ReadyAnchors:               []protocol.PrefixCacheAnchor{a2, a3},
		ExpectedPrefillTokensSaved: a3.TokenCount,
		StageMs:                    2,
	}) {
		t.Fatal("donation receipt rejected")
	}

	hit := &PendingRequest{
		RequestID: "lifecycle-hit", Model: "model", CachePlan: exactTestPlan(a1, a2, a3),
	}
	if err := prepareBoundTestCacheAttempt(r, hit, provider); err != nil {
		t.Fatal(err)
	}
	if !r.ApplyPrefixCacheLookupV2(provider.ID, &protocol.PrefixCacheLookupV2Message{
		RequestID: hit.RequestID, CacheReceiptNonce: preparedTestCacheMetadata(hit).CacheReceiptNonce,
		ModelID: "model", ModelAggregateHash: capability.ModelAggregateHash,
		PromptContractID: capability.PromptContractID, CacheEpoch: capability.CacheEpoch,
		CacheSeq: 3, PromptAnchor: a3, Outcome: "hit", Tier: "ssd",
		MatchedAnchor: &a3, ExpectedPrefillTokensSaved: a3.TokenCount, StageMs: 1,
	}) {
		t.Fatal("hit receipt rejected")
	}

	status := r.CacheRoutingLifecycleStatus()
	if status.SSDLookups != 2 || status.SSDMisses != 1 ||
		status.SSDDonations != 1 || status.SSDHits != 1 {
		t.Fatalf("lifecycle status=%+v", status)
	}
}

func TestExactV2LongestHolderChangesMultiProviderSelection(t *testing.T) {
	r, _, capability := newExactRoutingFixture(t)
	r.Disconnect("provider-a")
	cached := makeSchedulerProvider(t, r.Registry, "cached", "model", 100)
	cold := makeSchedulerProvider(t, r.Registry, "cold", "model", 100)
	for _, provider := range []*Provider{cached, cold} {
		provider.Mu().Lock()
		// Production accepts this capability only for the same advertised artifact.
		provider.Models[0].WeightHash = capability.ModelAggregateHash
		provider.PrefillTPS = 100
		provider.PrefixCacheProtocol = 2
		provider.PrefixCacheV2Models =
			map[string]protocol.PrefixCacheV2Capability{"model": capability}
		provider.BackendCapacity.Slots[0].ObservedPrefillTPS = 100
		provider.Mu().Unlock()
	}

	a1 := exactTestAnchor(1, "c")
	a2 := exactTestAnchor(2, "d")
	a3 := exactTestAnchor(3, "e")
	a4 := exactTestAnchor(4, "f")
	pr := &PendingRequest{
		RequestID: "seed-holder", Model: "model", CachePlan: exactTestPlan(a1, a2),
	}
	if err := prepareBoundTestCacheAttempt(r, pr, cached); err != nil {
		t.Fatal(err)
	}
	if !r.ApplyPrefixCacheLookupV2(cached.ID, &protocol.PrefixCacheLookupV2Message{
		RequestID: pr.RequestID, CacheReceiptNonce: preparedTestCacheMetadata(pr).CacheReceiptNonce,
		ModelID: "model", ModelAggregateHash: capability.ModelAggregateHash,
		PromptContractID: capability.PromptContractID, CacheEpoch: capability.CacheEpoch,
		CacheSeq: 1, PromptAnchor: a2, Outcome: "miss_absent", Tier: "ssd", StageMs: 1,
	}) {
		t.Fatal("seed lookup failed")
	}
	if !r.ApplyPrefixCacheReadyV2(cached.ID, &protocol.PrefixCacheReadyV2Message{
		RequestID: pr.RequestID, CacheReceiptNonce: preparedTestCacheMetadata(pr).CacheReceiptNonce,
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
		CachePlan:             boundTestCachePlan(r, exactTestPlan(a1, a2, a3, a4)),
	}
	selected, decision := r.ReserveProviderEx("model", next)
	if selected == nil {
		t.Fatalf("routing failed: %+v", decision)
	}
	if selected.ID != cached.ID || decision.CacheDiscountMs <= 0 ||
		decision.CacheEstimatedTTFTSavedMs <= 0 ||
		next.CacheSelectionEstimatedTTFTSavedMs != decision.CacheEstimatedTTFTSavedMs ||
		next.CacheSelectionMode != "active" || !next.CacheSelectionSelected {
		t.Fatalf("exact holder did not win: provider=%s decision=%+v request=%+v",
			selected.ID, decision, next)
	}
	selected.RemovePending(next.RequestID)
	r.SetProviderIdle(selected.ID)
	cached.Mu().Lock()
	cached.BackendCapacity.Slots[0].NumWaiting = 10
	cached.Mu().Unlock()
	busy := &PendingRequest{
		RequestID:             "route-busy-holder",
		Model:                 "model",
		EstimatedPromptTokens: a4.TokenCount,
		RequestedMaxTokens:    128,
		CachePlan:             boundTestCachePlan(r, exactTestPlan(a1, a2, a3, a4)),
	}
	selected, decision = r.ReserveProviderEx("model", busy)
	if selected == nil || selected.ID != cold.ID {
		t.Fatalf("busy holder overrode normal load cost: provider=%v decision=%+v",
			selected, decision)
	}
}

func TestExactRoutingDisabledV2CapabilityRemainsColdBaseline(t *testing.T) {
	r, provider, capability := newExactRoutingFixture(t)
	capability.Ready = false
	provider.Mu().Lock()
	provider.PrefixCacheV2Models["model"] = capability
	provider.Mu().Unlock()

	plan := exactTestPlan(exactTestAnchor(1, "c"))
	pr := &PendingRequest{RequestID: "disabled-v2", Model: "model", CachePlan: plan}
	if err := prepareBoundTestCacheAttempt(r, pr, provider); err != nil {
		t.Fatal(err)
	}
	if preparedTestCacheMetadata(pr).CacheReceiptNonce != "" || pr.CacheRoutingParticipates() {
		t.Fatal("disabled v2 capability was allowed to participate")
	}
}

func TestExactRoutingTrackerRemainsBoundedUnderConcurrency(t *testing.T) {
	tracker := newCacheIndexKernelFixture(cachetracker.Settings{TTL: time.Minute, MaxHolders: 2, MaxEntries: 128, MaxAttempts: 256})
	// The production kernel is caller-serialized; keep each holder/attempt
	// transaction under one lock, as the registry's receipt controller does.
	var mu sync.Mutex
	now := time.Now()
	var workers sync.WaitGroup
	for worker := 0; worker < 16; worker++ {
		workers.Add(1)
		go func(worker int) {
			defer workers.Done()
			for index := 0; index < 200; index++ {
				key := fmt.Sprintf("key-%d-%d", worker, index)
				nonce := fmt.Sprintf("nonce-%d-%d", worker, index)
				mu.Lock()
				tracker.UpsertHolderLocked(key, indexKernelHolder{
					ProviderID: fmt.Sprintf("provider-%d", worker),
					UpdatedAt:  now,
					ExpiresAt:  now.Add(time.Minute),
				})
				admitted := tracker.StoreAttemptLocked(nonce, indexKernelAttempt{
					RequestID:  fmt.Sprintf("request-%d-%d", worker, index),
					ProviderID: fmt.Sprintf("provider-%d", worker),
					CreatedAt:  now.Add(time.Duration(worker*200+index) * time.Nanosecond),
					ExpiresAt:  now.Add(time.Minute),
				})
				tracker.EnforceAttemptCapLocked()
				mu.Unlock()
				if !admitted {
					t.Error("bounded concurrency fixture insertion refused")
					return
				}
			}
		}(worker)
	}
	workers.Wait()
	mu.Lock()
	defer mu.Unlock()
	if tracker.config.Holders.Len() > tracker.config.MaxEntries ||
		tracker.config.Holders.BucketCount() > tracker.config.MaxEntries ||
		tracker.config.Attempts.Len() > tracker.config.MaxAttempts ||
		tracker.config.HolderOrder.Len() != tracker.config.Holders.Len() ||
		tracker.config.AttemptOrder.Len() != tracker.config.Attempts.Len() {
		t.Fatalf(
			"tracker exceeded bounds: holders=%d keys=%d holder_heap=%d attempts=%d attempt_heap=%d",
			tracker.config.Holders.Len(),
			tracker.config.Holders.BucketCount(),
			tracker.config.HolderOrder.Len(),
			tracker.config.Attempts.Len(),
			tracker.config.AttemptOrder.Len(),
		)
	}
}

func TestExactRoutingExpiryAndDisconnectRemoveConnectionEvidence(t *testing.T) {
	r, provider, capability := newExactRoutingFixture(t)
	anchor := exactTestAnchor(1, "c")
	plan := exactTestPlan(anchor)
	key := plan.BoundaryKey(r.routeKey, anchor)
	now := time.Now()
	r.tracker.UpsertHolderLocked(key, indexKernelHolder{
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
	capabilities := map[string]CacheRoutingCapability{
		provider.ID: {Provider: provider, Capability: capability},
	}
	if len(r.hints(
		plan, capabilities, now)) != 1 {
		t.Fatal("fresh holder was unavailable")
	}
	if len(r.hints(
		plan, capabilities, now.Add(2*time.Second))) != 0 {
		t.Fatal("expired holder remained available")
	}

	r.tracker.UpsertHolderLocked(key, indexKernelHolder{
		ProviderID: provider.ID, Provider: provider, ModelID: "model",
		ModelAggregateHash: capability.ModelAggregateHash,
		PromptContractID:   capability.PromptContractID,
		CacheEpoch:         capability.CacheEpoch, Anchor: anchor,
		StageMs:   1,
		UpdatedAt: now, ExpiresAt: now.Add(time.Minute),
	})
	r.Disconnect(provider.ID)
	if len(r.hints(
		plan, capabilities, now)) != 0 {
		t.Fatal("disconnect left connection-scoped holder evidence")
	}
	lifecycle := r.CacheRoutingLifecycleStatus()
	if lifecycle.HolderAdded != 2 ||
		lifecycle.HolderRemoved[string(cachetracker.RemovalTTL)] != 1 ||
		lifecycle.HolderRemoved[string(cachetracker.RemovalDisconnect)] != 1 {
		t.Fatalf("expiry/disconnect lifecycle counters = %+v", lifecycle)
	}
}

func TestExactRoutingHolderCapacityEvictionIsCounted(t *testing.T) {
	tracker := newReceiptKernelFixture(time.Minute, 1)
	now := time.Now()
	tracker.UpsertHolderLocked("boundary", indexKernelHolder{
		ProviderID: "first", UpdatedAt: now, ExpiresAt: now.Add(time.Minute),
	})
	tracker.UpsertHolderLocked("boundary", indexKernelHolder{
		ProviderID: "second", UpdatedAt: now.Add(time.Second), ExpiresAt: now.Add(time.Minute),
	})
	added := indexKernelMetrics(tracker.cacheIndexKernelFixture).Added
	removed := indexKernelMetrics(tracker.cacheIndexKernelFixture).Removed[string(cachetracker.RemovalCapacityEviction)]
	count := tracker.config.Holders.Len()
	if added != 2 || removed != 1 || count != 1 {
		t.Fatalf("capacity lifecycle added=%d removed=%d holders=%d", added, removed, count)
	}
}
