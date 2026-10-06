package registry_test

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheactivation"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheplan"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// firstSightRoutingFixture plans through the configured registry and a local
// sidecar, then routes over two equivalent cache-capable providers that hold
// no cache evidence, so only affinity can tell them apart.
type firstSightRoutingFixture struct {
	t        *testing.T
	registry *production.Registry
	client   *promptcontract.Client
	requests int

	mu   sync.Mutex
	next promptcontract.Plan
}

func newFirstSightRoutingFixture(t *testing.T, firstSightMinTokens int) *firstSightRoutingFixture {
	t.Helper()
	f := &firstSightRoutingFixture{t: t, registry: production.New(testLogger())}
	config := generationTestConfig(production.CacheRoutingOn)
	config.TTL, config.MaxHolders, config.FirstSightMinTokens = time.Minute, 4, firstSightMinTokens
	if err := f.registry.ConfigureCacheRouting(config); err != nil {
		t.Fatal(err)
	}
	capability := exactTestCapability("11111111-1111-1111-1111-111111111111")
	f.registry.SetModelCatalog([]production.CatalogEntry{{ID: capability.ModelID, WeightHash: capability.ModelAggregateHash}})
	for _, id := range []string{"machine-a", "machine-b"} {
		setTestProviderRates(checkpointPricingProvider(t, f.registry, id, capability), 1000, 100)
	}
	f.client = f.serveSidecar()
	return f
}

func (f *firstSightRoutingFixture) serveSidecar() *promptcontract.Client {
	f.t.Helper()
	root, err := filepath.EvalSymlinks("/tmp")
	if err != nil {
		f.t.Fatal(err)
	}
	temp, err := os.MkdirTemp(root, "cache-first-sight-")
	if err != nil {
		f.t.Fatal(err)
	}
	f.t.Cleanup(func() { _ = os.RemoveAll(temp) })
	socket := filepath.Join(temp, "sidecar.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		f.t.Fatal(err)
	}
	if err := os.Chmod(socket, 0o600); err != nil {
		f.t.Fatal(err)
	}
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		f.mu.Lock()
		plan := f.next
		f.mu.Unlock()
		_ = json.NewEncoder(w).Encode(plan)
	})}
	go func() { _ = server.Serve(listener) }()
	f.t.Cleanup(func() { _ = server.Close() })
	client := promptcontract.NewClient(promptcontract.ClientConfig{SocketPath: socket, RequestTimeout: 2 * time.Second})
	f.t.Cleanup(client.Close)
	return client
}

// plan asks the registry for the cache plan of a prompt of one conversation.
// Prompts of one conversation share every block they both have.
func (f *firstSightRoutingFixture) plan(promptTokens int, conversation uint32) production.CachePlan {
	f.t.Helper()
	blocks := demandTestPlan(&cacheplan.Generation{}, promptTokens, 0, conversation)
	sidecarPlan := promptcontract.Plan{PromptContractID: blocks.PromptContractID, PromptTokenCount: uint32(promptTokens)}
	for _, boundary := range blocks.Boundaries {
		sidecarPlan.BlockBoundaries = append(sidecarPlan.BlockBoundaries,
			promptcontract.Boundary{TokenCount: uint32(boundary.TokenCount), ChainHash: boundary.ChainHash})
	}
	last := sidecarPlan.BlockBoundaries[len(sidecarPlan.BlockBoundaries)-1].ChainHash
	sidecarPlan.LastCompleteBlockHash = &last
	f.mu.Lock()
	f.next = sidecarPlan
	f.mu.Unlock()
	f.requests++
	result := f.registry.PlanCacheRouteWithResult(context.Background(), f.client, production.CachePlanInput{
		Account: "account", Model: "model",
		PromptContractID: blocks.PromptContractID, ModelAggregateSHA256: blocks.ModelAggregateHash,
		Body: []byte(fmt.Sprintf(`{"model":"model","messages":[{"role":"user","content":"prompt %d"}]}`, f.requests)),
	})
	if result.Outcome != cacheactivation.CachePlanPlanned {
		f.t.Fatalf("prompt of %d tokens was not planned: %s", promptTokens, result.Outcome)
	}
	return result.Plan
}

// wireCounts are the two cache counts one prepared frame carries.
type wireCounts struct{ repeat, firstSight int }

// dispatch reserves a provider for the plan and returns it with the routing
// decision, the terminal cache diagnostics and the counts its frame carries.
func (f *firstSightRoutingFixture) dispatch(plan production.CachePlan) (*production.Provider, production.RoutingDecision, *production.PendingRequest, wireCounts) {
	f.t.Helper()
	f.requests++
	pr := &production.PendingRequest{RequestID: fmt.Sprintf("request-%d", f.requests), Model: "model", CachePlan: plan,
		EstimatedPromptTokens: plan.PromptTokenCount, RequestedMaxTokens: 128}
	p, decision, onWire := f.send(pr)
	return p, decision, pr, onWire
}

// send reserves a provider outside exclude for the request, reads the counts
// its prepared frame carries, and releases the provider as a dispatch that
// ended before any content does.
func (f *firstSightRoutingFixture) send(pr *production.PendingRequest, exclude ...string) (*production.Provider, production.RoutingDecision, wireCounts) {
	f.t.Helper()
	p, decision := f.registry.ReserveProviderEx("model", pr, exclude...)
	if p == nil {
		f.t.Fatalf("no provider reserved: %+v", decision)
	}
	if err := f.registry.PrepareCacheAttempt(pr, p); err != nil {
		f.t.Fatal(err)
	}
	var frame protocol.InferenceRequestMessage
	pr.CacheAttemptSnapshot().ApplyTo(&frame)
	if frame.CacheRepeatedPrefixTokens == nil {
		f.t.Fatal("prepared frame carries no repeated prefix count")
	}
	onWire := wireCounts{repeat: *frame.CacheRepeatedPrefixTokens, firstSight: frame.CacheFirstSightTokens}
	f.registry.ForgetCacheAttempt(pr)
	p.RemovePending(pr.RequestID)
	f.registry.SetProviderIdle(p.ID)
	return p, decision, onWire
}

func TestCacheFirstSightOffRoutesANovelPromptAsBefore(t *testing.T) {
	f := newFirstSightRoutingFixture(t, 0)
	plan := f.plan(7_000, 1)
	if plan.FirstSightTokens != 0 || plan.RepeatedPrefixTokens != 0 || plan.AffinityKey() != "" {
		t.Fatalf("novel plan: first sight=%d repeat=%d affinity key present=%v", plan.FirstSightTokens, plan.RepeatedPrefixTokens, plan.AffinityKey() != "")
	}
	_, decision, pr, onWire := f.dispatch(plan)
	if decision.SelectionPath != production.SelectionRandom || decision.NearTiePoolSize != 2 || pr.CacheOpportunity.AffinityApplied {
		t.Fatalf("equivalent providers were not spread at random: %+v", decision)
	}
	if onWire != (wireCounts{}) || pr.CacheOpportunityReason() != "no_repeat_observed" {
		t.Fatalf("frame carries %+v and the request reports %q, want neither count and no_repeat_observed", onWire, pr.CacheOpportunityReason())
	}
	if status := f.registry.CacheRoutingActivationStatus(); status.FirstSight != 0 || status.Planned != 1 {
		t.Fatalf("activation status=%+v, want one planned request and no first sight", status)
	}
}

// The first request of a conversation is told to keep its deepest stride
// boundary and is routed by the key its follow-up will derive, so the
// follow-up lands on the provider that wrote the checkpoint. The frame keeps
// the two counts apart: first sight never reads as an observed repeat, and a
// proven repeat carries no first-sight count.
func TestCacheFirstSightRoutesTheFollowUpToTheFirstRequestsProvider(t *testing.T) {
	f := newFirstSightRoutingFixture(t, 4_096)
	const conversations = 6
	for conversation := uint32(1); conversation <= conversations; conversation++ {
		first := f.plan(7_000, conversation)
		if first.FirstSightTokens != 6_144 || first.RepeatedPrefixTokens != 0 || first.AffinityKey() == "" {
			t.Fatalf("conversation %d: first sight=%d repeat=%d affinity key present=%v, want 6,144 kept and a key",
				conversation, first.FirstSightTokens, first.RepeatedPrefixTokens, first.AffinityKey() != "")
		}
		provider, decision, pr, onWire := f.dispatch(first)
		if decision.SelectionPath != production.SelectionPrefixAffinity || decision.CacheDiscountMs != 0 || pr.CacheSelectionSelected {
			t.Fatalf("conversation %d: first request was not placed by affinity alone: %+v", conversation, decision)
		}
		if onWire != (wireCounts{firstSight: 6_144}) || pr.CacheOpportunity.RepeatedPrefixTokens != 0 || pr.CacheOpportunityReason() != "no_repeat_observed" {
			t.Fatalf("conversation %d: frame carries %+v, diagnostics repeat=%d reason=%q; want first sight 6,144 beside repeat 0 and a novel request",
				conversation, onWire, pr.CacheOpportunity.RepeatedPrefixTokens, pr.CacheOpportunityReason())
		}

		followUp := f.plan(7_400, conversation)
		if followUp.FirstSightTokens != 0 || followUp.RepeatedPrefixTokens != 6_144 || followUp.AffinityKey() != first.AffinityKey() {
			t.Fatalf("conversation %d: follow-up first sight=%d repeat=%d same key=%v, want a repeat of 6,144 under the first request's key",
				conversation, followUp.FirstSightTokens, followUp.RepeatedPrefixTokens, followUp.AffinityKey() == first.AffinityKey())
		}
		again, decision, _, onWire := f.dispatch(followUp)
		if again != provider || decision.SelectionPath != production.SelectionPrefixAffinity || onWire != (wireCounts{repeat: 6_144}) {
			t.Fatalf("conversation %d: follow-up went to %s by %s carrying %+v, first request went to %s",
				conversation, again.ID, decision.SelectionPath, onWire, provider.ID)
		}
	}
	if status := f.registry.CacheRoutingActivationStatus(); status.FirstSight != conversations || status.Planned != 2*conversations {
		t.Fatalf("activation status=%+v, want %d first-sight plans among %d planned", status, conversations, 2*conversations)
	}
}

// A prompt below the configured minimum is planned and routed as a novel one.
func TestCacheFirstSightSkipsPromptsBelowTheMinimum(t *testing.T) {
	f := newFirstSightRoutingFixture(t, 8_192)
	plan := f.plan(7_000, 1)
	_, decision, _, onWire := f.dispatch(plan)
	if plan.FirstSightTokens != 0 || plan.AffinityKey() != "" || onWire != (wireCounts{}) || decision.SelectionPath != production.SelectionRandom {
		t.Fatalf("short prompt: first sight=%d affinity key present=%v wire=%+v path=%s",
			plan.FirstSightTokens, plan.AffinityKey() != "", onWire, decision.SelectionPath)
	}
	if status := f.registry.CacheRoutingActivationStatus(); status.FirstSight != 0 {
		t.Fatalf("activation status=%+v, want no first sight", status)
	}
}

// The plan owns the first-sight value, not an attempt. The dispatcher builds a
// pending request from the planned value for every attempt, so a request that
// is dispatched again asks its next provider to keep the same prefix.
func TestCacheFirstSightSecondDispatchStillCarriesTheKeptPrefix(t *testing.T) {
	f := newFirstSightRoutingFixture(t, 1_024)
	plan := f.plan(7_000, 1)
	attempt := func() *production.PendingRequest {
		return &production.PendingRequest{RequestID: "dispatched-twice", Model: "model", CachePlan: plan,
			EstimatedPromptTokens: plan.PromptTokenCount, RequestedMaxTokens: 128}
	}
	first, _, onWire := f.send(attempt())
	if onWire != (wireCounts{firstSight: 6_144}) {
		t.Fatalf("first dispatch carries %+v, want first sight 6,144 and repeat 0", onWire)
	}
	retry := attempt()
	second, _, onWire := f.send(retry, first.ID)
	if second == first || onWire != (wireCounts{firstSight: 6_144}) || retry.CachePlan.RepeatedPrefixTokens != 0 ||
		retry.CacheOpportunityReason() != "no_repeat_observed" {
		t.Fatalf("second dispatch went to %s carrying %+v with repeat=%d reason=%q; want another provider, first sight 6,144 on the wire and a novel request",
			second.ID, onWire, retry.CachePlan.RepeatedPrefixTokens, retry.CacheOpportunityReason())
	}
	if status := f.registry.CacheRoutingActivationStatus(); status.FirstSight != 1 || status.Planned != 1 {
		t.Fatalf("activation status=%+v, want one first-sight plan however often it is dispatched", status)
	}
}

// Affinity ranks only providers that could hold the prefix. With one
// cache-capable provider among equivalent ones, every conversation's key
// selects it; were the others eligible, rendezvous hashing would spread the
// conversations over all three.
func TestCacheFirstSightAffinityIgnoresProvidersThatCannotCache(t *testing.T) {
	f := newFirstSightRoutingFixture(t, 1_024)
	f.registry.Disconnect("machine-b")
	// The same weights and a ready capability, announced over protocol 1.
	legacy := checkpointPricingProvider(t, f.registry, "protocol-v1", exactTestCapability("33333333-3333-3333-3333-333333333333"))
	legacy.Mu().Lock()
	legacy.PrefixCacheProtocol = 1
	legacy.Mu().Unlock()
	setTestProviderRates(legacy, 1000, 100)
	otherContract := exactTestCapability("22222222-2222-2222-2222-222222222222")
	otherContract.PromptContractID = strings.Repeat("c", 64)
	setTestProviderRates(checkpointPricingProvider(t, f.registry, "other-contract", otherContract), 1000, 100)
	for conversation := uint32(1); conversation <= 8; conversation++ {
		plan := f.plan(7_000, conversation)
		if plan.FirstSightTokens != 6_144 || plan.AffinityKey() == "" {
			t.Fatalf("conversation %d: first sight=%d affinity key present=%v", conversation, plan.FirstSightTokens, plan.AffinityKey() != "")
		}
		provider, decision, pr, _ := f.dispatch(plan)
		if provider.ID != "machine-a" || decision.NearTiePoolSize != 3 || decision.SelectionPath != production.SelectionPrefixAffinity ||
			!pr.CacheOpportunity.AffinityApplied {
			t.Fatalf("conversation %d: went to %s by %s among %d near ties, want the cache-capable provider by affinity among 3",
				conversation, provider.ID, decision.SelectionPath, decision.NearTiePoolSize)
		}
	}
}

// Holder evidence can outlive the demand history, so a prompt that reads as
// novel may already be held. Measured credit decides then; first-sight
// affinity stays a tie-break among providers without it.
func TestCacheFirstSightAffinityYieldsToACreditedHolder(t *testing.T) {
	f := newCreditTestFixture(t)
	holder := f.holder(t, "holder")
	f.holder(t, "peer-a")
	f.holder(t, "peer-b")
	f.publish(t, holder, "donor", f.checkpoint, 100)
	// The plan was never observed, so the demand history has no entry for it.
	if !f.plan.ObserveRouteDemand(f.r.plans.generation, f.demand, f.r.routeKey, time.Now(), 1_024) ||
		f.plan.FirstSightTokens != f.checkpoint.TokenCount || f.plan.RepeatedPrefixTokens != 0 || f.plan.AffinityKey() == "" {
		t.Fatalf("held prompt was not prepared as a novel one: first sight=%d repeat=%d affinity key present=%v",
			f.plan.FirstSightTokens, f.plan.RepeatedPrefixTokens, f.plan.AffinityKey() != "")
	}
	for i := range 5 {
		selected, decision, pr := f.reserve(t, fmt.Sprintf("held-%d", i))
		if selected != holder || decision.CacheDiscountMs <= 0 || !pr.CacheSelectionSelected ||
			decision.SelectionPath == production.SelectionPrefixAffinity || pr.CacheOpportunity.AffinityApplied ||
			pr.CacheOpportunity.CreditedCandidates != 1 {
			t.Fatalf("first-sight affinity displaced the credited holder: %s %+v %+v", selected.ID, decision, pr.CacheOpportunity)
		}
	}
}
