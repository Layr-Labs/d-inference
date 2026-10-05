package inference_test

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/cold"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/conformance"
)

type privacyPlanningPressure struct {
	fixture       *privacyPlanningFixture
	provider      *registry.Provider
	large, target registry.CachePlan
	serial        int
	admitted      []*registry.PendingRequest
	witnessNonce  string
}

func (f *privacyPlanningFixture) referencePlan(t *testing.T, words int) registry.CachePlan {
	t.Helper()
	body := map[string]any{"model": f.planning.model, "max_tokens": 64,
		"messages": []any{map[string]any{"role": "user", "content": strings.Repeat("hello ", words) + privacyPlanningContent}}}
	promptcontract.SetRequestDate(body, time.Now())
	encoded, err := json.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}
	result := f.reg.PlanCacheRouteWithResult(f.ctx, f.planning.supervisor.Client(), registry.CachePlanInput{
		Account: privacyPlanningAccountA, Model: f.planning.model, PromptContractID: f.planning.contract,
		ModelAggregateSHA256: f.planning.aggregate, Body: encoded,
	})
	if result.Outcome != registry.CachePlanPlanned || !result.SidecarCalled || result.Plan.CacheScope == "" {
		t.Fatal("pressure setup did not obtain a genuine current real-sidecar plan")
	}
	return result.Plan
}

// No private budget setter, forged generation, changed anchor or oversized
// scalar. Public preparation retains these synthetic bookkeeping owners only;
// they are never provider pending work and publish no LOOKUP/READY evidence.
func newPrivacyPlanningPressure(t *testing.T, f *privacyPlanningFixture) *privacyPlanningPressure {
	t.Helper()
	// A complete HTTP/control witness comes before pressure, so a fixture or
	// ordinary-admission failure cannot be mistaken for byte-budget behavior.
	before := f.mark(t, privacyPlanningAccountA)
	done, cancel := f.start(t, privacyPlanningAccountA, "/v1/chat/completions",
		privacyPlanningBody(t, f.planning.model, "/v1/chat/completions", false, privacyPlanningAccountB))
	result := f.finish(t, done)
	cancel()
	f.assertSuccess(t, before, privacyPlanningAccountA, "/v1/chat/completions", false, result, 1, true)
	f.forgetOwned(t)
	p := &privacyPlanningPressure{fixture: f, provider: f.reg.GetProvider(f.providers[0].registryID),
		large: f.referencePlan(t, 4096), target: f.referencePlan(t, 300)}
	if p.provider == nil || len(p.large.Boundaries) < 16 || len(p.target.Boundaries) != 1 {
		t.Fatal("bounded pressure fixture requires a >=16-boundary plan and a one-boundary target")
	}
	refused := false
	for i := 0; i < 16_384; i++ {
		request := p.prepare(t, p.large)
		if !request.CacheRoutingParticipates() {
			refused = true
			break
		}
		p.admitted = append(p.admitted, request)
	}
	if !refused || len(p.admitted) == 0 {
		t.Fatal("default byte-pressure witness absent within finite bound")
	}
	p.fillRemainder(t)
	// A valid miss on a retained synthetic owner supplies a nontrivial receipt
	// control without publishing a holder or granting an admission discount.
	witness := p.admitted[len(p.admitted)-1]
	var metadata protocol.InferenceRequestMessage
	witness.CacheAttemptSnapshot().ApplyTo(&metadata)
	p.witnessNonce = metadata.CacheReceiptNonce
	lookup := p.lookup(witness.RequestID)
	if p.witnessNonce == "" || !f.reg.ApplyPrefixCacheLookupV2Result(p.provider.ID, lookup).Accepted {
		t.Fatal("valid retained-owner miss receipt control was rejected")
	}
	// Public release/readmit excludes a stale generation/capability refusal as
	// the explanation. Restore pressure before any measured HTTP request.
	f.reg.ForgetCacheAttempt(p.admitted[0])
	control := p.prepare(t, p.target)
	if !control.CacheRoutingParticipates() {
		t.Fatal("same-plan readmission did not recover after one owned refund")
	}
	p.fillRemainder(t)
	if holders, attempts := f.reg.CacheRoutingStateCounts(); holders != 0 || attempts == 0 || attempts >= 50_000 {
		t.Fatal("pressure did not isolate bytes below count capacity with zero cache holders")
	}
	t.Logf("synthetic_preparation_calls=%d default_logical_byte_limit=67108864; not RSS or model work", p.serial)
	return p
}

func (p *privacyPlanningPressure) lookup(requestID string) *protocol.PrefixCacheLookupV2Message {
	capability := p.fixture.capability
	return &protocol.PrefixCacheLookupV2Message{Type: "prefix_cache_lookup_v2", RequestID: requestID,
		CacheReceiptNonce: p.witnessNonce, ModelID: capability.ModelID, ModelAggregateHash: capability.ModelAggregateHash,
		PromptContractID: capability.PromptContractID, CacheEpoch: capability.CacheEpoch, CacheSeq: 1,
		PromptAnchor: p.large.Boundaries[len(p.large.Boundaries)-1], Outcome: "miss_absent", Tier: "ssd", StageMs: 1}
}

func (p *privacyPlanningPressure) assertBorrowedReceiptsRejected(t *testing.T, refusedRequestID string) {
	t.Helper()
	if result := p.fixture.reg.ApplyPrefixCacheLookupV2Result(p.provider.ID, p.lookup(refusedRequestID)); result.Accepted || result.Reason != registry.CacheReceiptAttemptBinding {
		t.Fatalf("borrowed nonce authorized a refused request lookup: %+v", result)
	}
	capability := p.fixture.capability
	anchor := p.large.Boundaries[len(p.large.Boundaries)-1]
	ready := &protocol.PrefixCacheReadyV2Message{Type: "prefix_cache_ready_v2", RequestID: refusedRequestID,
		CacheReceiptNonce: p.witnessNonce, ModelID: capability.ModelID, ModelAggregateHash: capability.ModelAggregateHash,
		PromptContractID: capability.PromptContractID, CacheEpoch: capability.CacheEpoch, CacheSeq: 2,
		Outcome: "ready", Tier: "ssd", ReadyAnchors: []protocol.PrefixCacheAnchor{anchor},
		ExpectedPrefillTokensSaved: anchor.TokenCount, StageMs: 1}
	if result := p.fixture.reg.ApplyPrefixCacheReadyV2Result(p.provider.ID, ready); result.Accepted || result.Reason != registry.CacheReceiptAttemptBinding {
		t.Fatalf("borrowed nonce authorized a refused request READY: %+v", result)
	}
	if holders, _ := p.fixture.reg.CacheRoutingStateCounts(); holders != 0 {
		t.Fatal("refused/borrowed evidence published a cache holder")
	}
}

func (p *privacyPlanningPressure) prepare(t *testing.T, plan registry.CachePlan) *registry.PendingRequest {
	t.Helper()
	if err := p.fixture.ctx.Err(); err != nil {
		t.Fatal(err)
	}
	p.serial++
	request := &registry.PendingRequest{RequestID: fmt.Sprintf("%08x-0000-4000-8000-000000000000", p.serial),
		Model: p.fixture.planning.model, CachePlan: plan, EstimatedPromptTokens: plan.PromptTokenCount}
	p.fixture.remember(request)
	if err := p.fixture.reg.PrepareCacheAttempt(request, p.provider); err != nil {
		t.Fatalf("optional preparation became an inference error: %v", err)
	}
	if !request.CacheRoutingParticipates() {
		var frame protocol.InferenceRequestMessage
		request.CacheAttemptSnapshot().ApplyTo(&frame)
		if frame.CacheReceiptNonce != "" || frame.CacheScope != "" || frame.PrefixCacheProtocol != 0 ||
			frame.CacheReceiptBoundaryMode != "" || !request.CacheRoutingTelemetryEligible() {
			t.Fatal("refused public preparation retained cache metadata or lost ordinary telemetry")
		}
	}
	return request
}

func (p *privacyPlanningPressure) fillRemainder(t *testing.T) {
	t.Helper()
	for i := 0; i < 16; i++ {
		if !p.prepare(t, p.target).CacheRoutingParticipates() {
			return
		}
	}
	t.Fatal("small-remainder fixture bound exceeded; do not increase caps to force a pass")
}

func TestCachePlanningComposedBudgetPressureKeepsOrdinaryDispatch(t *testing.T) {
	f := newPrivacyPlanningFixture(t, 1)
	pressure := newPrivacyPlanningPressure(t, f)
	for _, endpoint := range []string{"/v1/chat/completions", "/v1/responses", "/v1/completions", "/v1/messages"} {
		for _, stream := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/stream=%t", endpoint, stream), func(t *testing.T) {
				before := f.mark(t, privacyPlanningAccountA)
				_, retained := f.reg.CacheRoutingStateCounts()
				done, cancel := f.start(t, privacyPlanningAccountA, endpoint,
					privacyPlanningBody(t, f.planning.model, endpoint, stream, privacyPlanningAccountB))
				defer cancel()
				records := f.assertSuccess(t, before, privacyPlanningAccountA, endpoint, stream, f.finish(t, done), 1, false)
				pressure.assertBorrowedReceiptsRejected(t, records[0].frame.RequestID)
				if _, after := f.reg.CacheRoutingStateCounts(); after != retained {
					t.Fatal("byte-refused HTTP attempt retained a record or removed an unrelated hold")
				}
			})
		}
	}
	t.Run("refund_restores_participation", func(t *testing.T) {
		f.forgetOwned(t)
		before := f.mark(t, privacyPlanningAccountA)
		done, cancel := f.start(t, privacyPlanningAccountA, "/v1/chat/completions",
			privacyPlanningBody(t, f.planning.model, "/v1/chat/completions", false, privacyPlanningAccountB))
		defer cancel()
		f.assertSuccess(t, before, privacyPlanningAccountA, "/v1/chat/completions", false, f.finish(t, done), 1, true)
	})
}

func TestCachePlanningComposedBudgetPressureRetry(t *testing.T) {
	f := newPrivacyPlanningFixture(t, 2)
	newPrivacyPlanningPressure(t, f)
	before := f.mark(t, privacyPlanningAccountA)
	f.failNext.Store(true)
	done, cancel := f.start(t, privacyPlanningAccountA, "/v1/chat/completions",
		privacyPlanningBody(t, f.planning.model, "/v1/chat/completions", true, privacyPlanningAccountB))
	defer cancel()
	records := f.assertSuccess(t, before, privacyPlanningAccountA, "/v1/chat/completions", true, f.finish(t, done), 2, false)
	if records[0].provider == records[1].provider || !records[0].deadline.Equal(records[1].deadline) {
		t.Fatal("retry did not preserve provider separation and the original absolute deadline")
	}
}

func TestCachePlanningComposedBudgetPressureQueueAndCancellation(t *testing.T) {
	for _, canceled := range []bool{false, true} {
		t.Run(fmt.Sprintf("cancel=%t", canceled), func(t *testing.T) {
			f := newPrivacyPlanningFixture(t, 1)
			newPrivacyPlanningPressure(t, f)
			if !cold.New(nil, nil).QueueBeforeShedEnabled() {
				t.Fatal("fixture requires the unchanged default queue-before-shed behavior")
			}
			f.reg.SetDedicatedModels([]string{f.planning.model})
			provider := f.reg.GetProvider(f.providers[0].registryID)
			provider.Mu().Lock()
			provider.PrefillTPS = 100_000 // This synthetic provider completes immediately; keep the normal TTFT gate enabled.
			provider.Mu().Unlock()
			capacity := func(used int64) {
				writeAdaptiveHeartbeat(t, f.ctx, f.providers[0].conn, f.planning.model, &protocol.BackendCapacity{
					TotalMemoryGB: 64, Slots: []protocol.BackendSlotCapacity{{Model: f.planning.model, State: "running",
						MaxConcurrency: 1, ActiveTokenBudgetUsed: used, ActiveTokenBudgetMax: 1000}},
				})
				awaitCondition(t, time.Second, func() bool {
					provider.Mu().Lock()
					defer provider.Mu().Unlock()
					return provider.BackendCapacity != nil && len(provider.BackendCapacity.Slots) == 1 &&
						provider.BackendCapacity.Slots[0].ActiveTokenBudgetUsed == used
				}, "truthful queued capacity heartbeat")
			}
			capacity(950)
			before := f.mark(t, privacyPlanningAccountA)
			_, retained := f.reg.CacheRoutingStateCounts()
			minimumBudget := f.server.FirstContentDeadline(f.planning.model, 0)
			// The account policy answers per request; an exempt account gets a zero budget.
			accountBudget, err := f.server.firstContentPolicy.Deadline(
				slaAccountRequest(privacyPlanningAccountA), f.planning.model, f.planning.model, 0)
			if enabled := accountBudget > 0; err != nil || !enabled || minimumBudget != 3*time.Second {
				t.Fatal("queue cancellation fixture lost its unchanged account deadline policy")
			}
			// This precedes server receipt and omits the nonnegative token slope,
			// so it is a conservative lower bound on the original writer deadline.
			deadlineFloor := time.Now().Add(minimumBudget)
			done, cancel := f.start(t, privacyPlanningAccountA, "/v1/chat/completions",
				privacyPlanningBody(t, f.planning.model, "/v1/chat/completions", true, privacyPlanningAccountB), "prefer")
			defer cancel()
			awaitCondition(t, 2*time.Second, func() bool { return f.reg.Queue().QueueSize(f.planning.model) == 1 }, "request enters actual queue")
			if f.providers[0].dispatchCount() != before.dispatches {
				t.Fatal("queued request dispatched before ordinary capacity became available")
			}
			if canceled {
				cancel()
				result := f.finish(t, done)
				if !errors.Is(result.err, context.Canceled) {
					t.Fatalf("caller cancellation was replaced by success/error: %v status=%d", result.err, result.status)
				}
				awaitCondition(t, 2*time.Second, func() bool { return f.reg.Queue().QueueSize(f.planning.model) == 0 && f.server.server.Inflight() == 0 }, "canceled queue owner drains")
				f.assertPlannedOnce(t, before)
				if f.providers[0].dispatchCount() != before.dispatches || len(f.records) != 0 {
					t.Fatal("canceled queued request dispatched or charged usage")
				}
				conformance.Eventually(t, func() bool {
					return f.store.GetBalance(privacyPlanningAccountA) == before.balance &&
						len(f.store.UsageByConsumer(privacyPlanningAccountA)) == before.usage &&
						f.outstandingHold(t, privacyPlanningAccountA) == 0
				}, "canceled queued billing/hold cleanup")
				// Release real capacity only after cancellation has been observed.
				// Expiry must not supply the rejection, and the provider stays live
				// across a quiet window longer than the 20ms trailing heartbeat drain.
				const quietWindow = 200 * time.Millisecond
				capacity(0)
				if time.Until(deadlineFloor) < quietWindow+500*time.Millisecond {
					t.Fatal("insufficient original deadline room for live post-cancel drain control")
				}
				quiet := time.NewTimer(quietWindow)
				defer quiet.Stop()
				tick := time.NewTicker(5 * time.Millisecond)
				defer tick.Stop()
				for {
					select {
					case <-f.providers[0].done:
						t.Fatal("provider ended during live post-cancel drain control")
					default:
					}
					holders, attempts := f.reg.CacheRoutingStateCounts()
					if f.providers[0].dispatchCount() != before.dispatches || len(f.records) != 0 ||
						provider.PendingCount() != 0 || f.reg.Queue().QueueSize(f.planning.model) != 0 ||
						f.server.server.Inflight() != 0 || holders != 0 || attempts != retained ||
						f.store.GetBalance(privacyPlanningAccountA) != before.balance ||
						len(f.store.UsageByConsumer(privacyPlanningAccountA)) != before.usage ||
						f.outstandingHold(t, privacyPlanningAccountA) != 0 {
						t.Fatal("restored capacity revived canceled dispatch, ownership or billing")
					}
					select {
					case <-f.ctx.Done():
						t.Fatal("fixture ended during live post-cancel drain control")
					case <-quiet.C:
						if time.Until(deadlineFloor) < 250*time.Millisecond {
							t.Fatal("original deadline expired or lost margin during post-cancel control")
						}
						f.assertPlannedOnce(t, before)
						return
					case <-tick.C:
					}
				}
			}
			capacity(0)
			f.assertSuccess(t, before, privacyPlanningAccountA, "/v1/chat/completions", true, f.finish(t, done), 1, false)
			if f.reg.Queue().QueueSize(f.planning.model) != 0 {
				t.Fatal("queued request did not drain")
			}
		})
	}
}
