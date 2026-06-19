package api

// Regression tests for the "client gone after commit, provider completed"
// outcome.
//
// When a consumer disconnects AFTER the response committed (first token sent)
// and the provider then COMPLETES, the request is settled from the parked
// billing record: the provider IS paid, the consumer IS charged, and it is NOT
// counted as a provider failure. The route outcome is partial_success with
// error_class client_gone_after_commit_provider_completed.
//
// These tests pin that composed invariant end-to-end through handleComplete (the
// component tests in settlement_test.go and route_outcome_test.go exercise the
// pieces, but not the full money + reputation + outcome path together). They also
// pin the exactly-once boundary from the other direction: once the settlement
// grace has refunded, a late provider terminal is a no-op (no double pay/charge).

import (
	"reflect"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// parkConsumerGone reproduces the post-commit-disconnect lifecycle: the request
// was pending on the provider, the consumer-side handler parked it for settlement
// (holdForSettlement), then removed it from the provider's pending set. After
// this, a provider terminal reaching handleComplete sees the request only in the
// settlement holder (claimSettlement), so consumerGone == true.
func parkConsumerGone(srv *Server, provider *registry.Provider, pr *registry.PendingRequest) {
	provider.AddPending(pr)
	srv.holdForSettlement(pr)
	provider.RemovePending(pr.RequestID)
}

// findRouteRecord returns the stored route record for requestID, or nil.
func findRouteRecord(st *store.MemoryStore, requestID string) *store.InferenceRouteRecord {
	for _, r := range st.InferenceRouteRecordsSince(time.Time{}) {
		if r.RequestID == requestID {
			rec := r
			return &rec
		}
	}
	return nil
}

// TestHandleCompleteClientGoneAfterCommitSettlesAndPays is the core
// regression test: a parked (consumer-gone) request that the provider completes
// must pay the provider, charge the consumer exactly the actual cost, count as a
// job SUCCESS (never a failure), and record a partial_success route outcome.
func TestHandleCompleteClientGoneAfterCommitSettlesAndPays(t *testing.T) {
	srv, st, ledger := billingTestServer(t)
	// Long grace so handleComplete deterministically claims the parked record
	// first; the timer fires well after the test and then no-ops.
	srv.settleGrace = 5 * time.Second

	model := "client-gone-after-commit-model"
	accountID := "client-gone-provider-account"
	provider := srv.registry.Register("client-gone-provider", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
	})
	provider.Mu().Lock()
	provider.AccountID = accountID
	provider.Mu().Unlock()

	usage := protocol.UsageInfo{PromptTokens: 1000, CompletionTokens: 500}
	expectedCost := payments.CalculateCost(model, usage.PromptTokens, usage.CompletionTokens)
	expectedPayout := payments.ProviderPayout(expectedCost)

	consumerID := testConsumerID
	initialBalance := ledger.Balance(consumerID)
	// Reserve MORE than the final cost so the settlement-refund branch is also
	// exercised: the consumer must end up debited exactly expectedCost.
	reserved := expectedCost * 3
	if err := ledger.Charge(consumerID, reserved, "reserve:"+consumerID); err != nil {
		t.Fatalf("reserve balance: %v", err)
	}

	pr := &registry.PendingRequest{
		RequestID:        "client-gone-after-commit",
		Model:            model,
		ConsumerKey:      consumerID,
		ReservedMicroUSD: reserved,
		ChunkCh:          make(chan string, 1),
		CompleteCh:       make(chan protocol.UsageInfo, 1),
		ErrorCh:          make(chan protocol.InferenceErrorMessage, 1),
	}

	// Pre-create the route row so the (best-effort, async) outcome update lands.
	if err := st.RecordInferenceRoute(&store.InferenceRouteRecord{
		RequestID:  pr.RequestID,
		Attempt:    pr.Attempt,
		Model:      model,
		ProviderID: provider.ID,
	}); err != nil {
		t.Fatalf("record route: %v", err)
	}

	parkConsumerGone(srv, provider, pr)

	srv.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{
		Type:      protocol.TypeInferenceComplete,
		RequestID: pr.RequestID,
		Usage:     usage,
	})

	// (1) Provider payout credited (provider credit runs under settlementWg, which
	// handleComplete waits on, so it is observable synchronously here).
	if got := st.GetWithdrawableBalance(accountID); got != expectedPayout {
		t.Errorf("provider payout = %d, want %d (provider must be paid for a completed-after-disconnect request)", got, expectedPayout)
	}

	// (2) Consumer charged exactly the actual cost (reservation finalized; excess
	// refunded; not fully refunded).
	if got := ledger.Balance(consumerID); got != initialBalance-expectedCost {
		t.Errorf("consumer balance = %d, want %d (charged exactly totalCost %d, not refunded/over-charged)",
			got, initialBalance-expectedCost, expectedCost)
	}
	usageEntries := ledger.Usage(consumerID)
	if len(usageEntries) != 1 {
		t.Fatalf("usage entries = %d, want 1 (usage recorded even when consumer gone)", len(usageEntries))
	}
	if usageEntries[0].CostMicroUSD != expectedCost {
		t.Errorf("usage cost = %d, want %d", usageEntries[0].CostMicroUSD, expectedCost)
	}

	// (3) RecordJobSuccess recorded; partial_success is NOT a provider failure.
	p := srv.registry.GetProvider(provider.ID)
	if p == nil {
		t.Fatal("provider missing after complete")
	}
	if p.Reputation.SuccessfulJobs != 1 {
		t.Errorf("successful_jobs = %d, want 1", p.Reputation.SuccessfulJobs)
	}
	if p.Reputation.FailedJobs != 0 {
		t.Errorf("failed_jobs = %d, want 0 (client-gone-after-commit must not penalize the provider)", p.Reputation.FailedJobs)
	}

	// (4) Route outcome = partial_success / client_gone_after_commit_provider_completed.
	// The outcome write is best-effort async (telemetry sink), so poll for it.
	deadline := time.Now().Add(2 * time.Second)
	var rec *store.InferenceRouteRecord
	for time.Now().Before(deadline) {
		if rec = findRouteRecord(st, pr.RequestID); rec != nil && rec.FinalStatus != "" {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if rec == nil {
		t.Fatal("route record not found")
	}
	if rec.FinalStatus != "partial_success" {
		t.Errorf("route final_status = %q, want partial_success", rec.FinalStatus)
	}
	if rec.ErrorClass != "client_gone_after_commit_provider_completed" {
		t.Errorf("route error_class = %q, want client_gone_after_commit_provider_completed", rec.ErrorClass)
	}
	if rec.CompletionTokens != usage.CompletionTokens || rec.PromptTokens != usage.PromptTokens {
		t.Errorf("route token counts = (%d prompt, %d completion), want (%d, %d)",
			rec.PromptTokens, rec.CompletionTokens, usage.PromptTokens, usage.CompletionTokens)
	}
	if rec.CostMicroUSD != expectedCost {
		t.Errorf("route cost_micro_usd = %d, want %d", rec.CostMicroUSD, expectedCost)
	}
}

// TestHandleCompleteClientGoneAfterCommitNotAProviderFailure isolates the
// reputation invariant: settling a parked completion records a SUCCESS and never
// increments FailedJobs, so routing (which scores on Reputation.Score()) does not
// deroute a provider for consumer-side disconnects.
func TestHandleCompleteClientGoneAfterCommitNotAProviderFailure(t *testing.T) {
	srv, _, ledger := billingTestServer(t)
	srv.settleGrace = 5 * time.Second

	model := "client-gone-no-fault-model"
	provider := srv.registry.Register("client-gone-no-fault-provider", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
	})

	consumerID := testConsumerID
	usage := protocol.UsageInfo{PromptTokens: 100, CompletionTokens: 200}
	cost := payments.CalculateCost(model, usage.PromptTokens, usage.CompletionTokens)
	if err := ledger.Charge(consumerID, cost, "reserve:"+consumerID); err != nil {
		t.Fatalf("reserve balance: %v", err)
	}

	pr := &registry.PendingRequest{
		RequestID:        "client-gone-no-fault",
		Model:            model,
		ConsumerKey:      consumerID,
		ReservedMicroUSD: cost,
	}
	parkConsumerGone(srv, provider, pr)

	srv.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{
		Type:      protocol.TypeInferenceComplete,
		RequestID: pr.RequestID,
		Usage:     usage,
	})

	p := srv.registry.GetProvider(provider.ID)
	if p == nil {
		t.Fatal("provider missing after complete")
	}
	if p.Reputation.FailedJobs != 0 {
		t.Errorf("failed_jobs = %d, want 0", p.Reputation.FailedJobs)
	}
	if p.Reputation.SuccessfulJobs != 1 {
		t.Errorf("successful_jobs = %d, want 1", p.Reputation.SuccessfulJobs)
	}
	if p.Reputation.TotalJobs != 1 {
		t.Errorf("total_jobs = %d, want 1", p.Reputation.TotalJobs)
	}
}

// TestHandleCompleteAfterGraceExpiryIsNoOp pins exactly-once settlement from the
// refund side: once the settlement grace has refunded the reservation, a late
// provider terminal must NOT pay the provider, re-charge, or double-refund the
// consumer, or count a job — the request is already gone from both the pending
// set and the holder.
func TestHandleCompleteAfterGraceExpiryIsNoOp(t *testing.T) {
	srv, st, ledger := billingTestServer(t)
	srv.settleGrace = 50 * time.Millisecond

	model := "late-terminal-model"
	accountID := "late-terminal-account"
	provider := srv.registry.Register("late-terminal-provider", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
	})
	provider.Mu().Lock()
	provider.AccountID = accountID
	provider.Mu().Unlock()

	consumerID := testConsumerID
	initialBalance := ledger.Balance(consumerID)
	const reserved int64 = 2_000_000
	if err := ledger.Charge(consumerID, reserved, "reserve:"+consumerID); err != nil {
		t.Fatalf("reserve balance: %v", err)
	}

	pr := &registry.PendingRequest{
		RequestID:            "late-terminal",
		Model:                model,
		ConsumerKey:          consumerID,
		BaseReservedMicroUSD: reserved,
		ReservedMicroUSD:     reserved,
	}
	parkConsumerGone(srv, provider, pr)

	// Wait for the grace timer to refund the reservation.
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if ledger.Balance(consumerID) == initialBalance {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if got := ledger.Balance(consumerID); got != initialBalance {
		t.Fatalf("balance after grace = %d, want %d (reservation refunded)", got, initialBalance)
	}

	// Late provider terminal: must be a no-op (unknown request — already settled).
	srv.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{
		Type:      protocol.TypeInferenceComplete,
		RequestID: pr.RequestID,
		Usage:     protocol.UsageInfo{PromptTokens: 1000, CompletionTokens: 500},
	})

	if got := ledger.Balance(consumerID); got != initialBalance {
		t.Errorf("consumer balance after late terminal = %d, want %d (no re-charge / double refund)", got, initialBalance)
	}
	if got := st.GetWithdrawableBalance(accountID); got != 0 {
		t.Errorf("provider payout = %d, want 0 (no payout once the grace already refunded)", got)
	}
	p := srv.registry.GetProvider(provider.ID)
	if p == nil {
		t.Fatal("provider missing")
	}
	if p.Reputation.SuccessfulJobs != 0 || p.Reputation.FailedJobs != 0 {
		t.Errorf("reputation = (%d success, %d fail), want (0, 0) — a dropped late terminal counts no job",
			p.Reputation.SuccessfulJobs, p.Reputation.FailedJobs)
	}
}

// TestCompleteRouteOutcomeConsumerGoneClassification pins the outcome mapping
// that handleComplete relies on: consumer present → success/empty; consumer gone
// after commit → partial_success/client_gone_after_commit_provider_completed,
// with token/cost passthrough.
func TestCompleteRouteOutcomeConsumerGoneClassification(t *testing.T) {
	pr := &registry.PendingRequest{RequestID: "route-map"}
	usage := protocol.UsageInfo{PromptTokens: 10, CompletionTokens: 20, ReasoningTokens: 3}

	clean := completeRouteOutcome(pr, usage, 1234, false)
	if clean.FinalStatus != "success" || clean.ErrorClass != "" {
		t.Fatalf("clean outcome = %q/%q, want success/empty", clean.FinalStatus, clean.ErrorClass)
	}

	gone := completeRouteOutcome(pr, usage, 1234, true)
	if gone.FinalStatus != "partial_success" {
		t.Errorf("gone final_status = %q, want partial_success", gone.FinalStatus)
	}
	if gone.ErrorClass != "client_gone_after_commit_provider_completed" {
		t.Errorf("gone error_class = %q, want client_gone_after_commit_provider_completed", gone.ErrorClass)
	}
	if gone.PromptTokens != usage.PromptTokens || gone.CompletionTokens != usage.CompletionTokens ||
		gone.ReasoningTokens != usage.ReasoningTokens || gone.CostMicroUSD != 1234 {
		t.Errorf("outcome passthrough wrong: %+v", gone)
	}
}

// TestPartialSuccessMetricNamesAndTags pins the wire contract for the new
// counters (names + tag shape) and verifies the emit helpers are nil-safe when
// Datadog is unconfigured (the case in every unit test).
func TestPartialSuccessMetricNamesAndTags(t *testing.T) {
	if metricPartialSuccess != "inference.partial_success" {
		t.Errorf("metricPartialSuccess = %q", metricPartialSuccess)
	}
	if metricClientCancellations != "inference.client_cancellations" {
		t.Errorf("metricClientCancellations = %q", metricClientCancellations)
	}
	if metricNoTerminalAfterCancel != "inference.no_terminal_after_cancel" {
		t.Errorf("metricNoTerminalAfterCancel = %q", metricNoTerminalAfterCancel)
	}
	if errorClassClientGoneAfterCommitCompleted != "client_gone_after_commit_provider_completed" {
		t.Errorf("errorClassClientGoneAfterCommitCompleted = %q", errorClassClientGoneAfterCommitCompleted)
	}
	if clientCancelPhaseBeforeFirstToken != "before_first_token" || clientCancelPhaseAfterCommit != "after_commit" {
		t.Errorf("phase constants = %q/%q", clientCancelPhaseBeforeFirstToken, clientCancelPhaseAfterCommit)
	}

	if got := partialSuccessTags("m", "c"); !reflect.DeepEqual(got, []string{"model:m", "error_class:c"}) {
		t.Errorf("partialSuccessTags = %v", got)
	}
	if got := clientCancellationTags("m", clientCancelPhaseAfterCommit); !reflect.DeepEqual(got, []string{"model:m", "phase:after_commit"}) {
		t.Errorf("clientCancellationTags = %v", got)
	}

	// Nil-safety: no Datadog client configured in tests; helpers must not panic.
	srv, _, _ := billingTestServer(t)
	srv.recordPartialSuccessCompletion("m", errorClassClientGoneAfterCommitCompleted)
	srv.recordClientCancellation("m", clientCancelPhaseBeforeFirstToken)
	srv.recordClientCancellation("m", clientCancelPhaseAfterCommit)
	srv.recordNoTerminalAfterCancel("m")
}
