package api

// Attempt-usage observability (deadline incident fix): a typed error terminal
// can carry the engine-reconciled partial usage of the failed attempt
// (InferenceErrorMessage.AttemptUsage). The coordinator persists those token
// counts on the route row — the incident's "every strict route had null
// prompt_tokens/completion_tokens" gap — WITHOUT touching billing: refunds,
// reservations, earnings, and cost stay exactly as for a usage-less error.

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func attemptUsageErrMsg(reqID string, usage *protocol.UsageInfo) protocol.InferenceErrorMessage {
	return protocol.InferenceErrorMessage{
		Type:          protocol.TypeInferenceError,
		RequestID:     reqID,
		Error:         "request exceeded safety deadline",
		StatusCode:    504,
		TerminalCause: terminalCauseSafetyDeadline,
		AttemptUsage:  usage,
	}
}

// Every provider-error route-outcome constructor must carry the attempt usage
// when present, and CompletionTokensSet must force-persist the authoritative
// count (even 0) instead of leaving NULL.
func TestProviderErrorOutcomesCarryAttemptUsage(t *testing.T) {
	usage := &protocol.UsageInfo{PromptTokens: 123, CompletionTokens: 456, ReasoningTokens: 7}
	pr := &registry.PendingRequest{RequestID: "req-usage", Model: "test-model"}
	msg := attemptUsageErrMsg(pr.RequestID, usage)

	cases := []struct {
		name    string
		outcome *store.InferenceRouteOutcome
	}{
		{"post_commit", postCommitProviderErrorOutcome(pr, msg)},
		{"pre_response", preResponseProviderErrorOutcome(pr, msg)},
		{"pre_commit", preCommitProviderErrorOutcome(pr, msg)},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			out := tc.outcome
			if out.PromptTokens != 123 || out.CompletionTokens != 456 || out.ReasoningTokens != 7 {
				t.Errorf("tokens = %d/%d/%d, want 123/456/7",
					out.PromptTokens, out.CompletionTokens, out.ReasoningTokens)
			}
			if !out.CompletionTokensSet {
				t.Error("CompletionTokensSet must be true when attempt usage is present")
			}
			// ZERO billing: attempt usage must never invent a route cost.
			if out.CostMicroUSD != 0 {
				t.Errorf("CostMicroUSD = %d, want 0 (observability only)", out.CostMicroUSD)
			}
		})
	}

	// The client-error branch of preCommitProviderErrorOutcome keeps usage too.
	clientMsg := attemptUsageErrMsg(pr.RequestID, usage)
	clientMsg.StatusCode = 400
	clientMsg.TerminalCause = ""
	if out := preCommitProviderErrorOutcome(pr, clientMsg); out.PromptTokens != 123 || out.CompletionTokens != 456 {
		t.Errorf("client-error branch tokens = %d/%d, want 123/456", out.PromptTokens, out.CompletionTokens)
	}
}

// Legacy regression: without attempt usage the outcomes look exactly like
// before — zero token values, with CompletionTokensSet still governed by the
// terminal-status force rules (error=true, partial_success=false).
func TestProviderErrorOutcomesWithoutAttemptUsageUnchanged(t *testing.T) {
	pr := &registry.PendingRequest{RequestID: "req-legacy", Model: "test-model"}
	msg := protocol.InferenceErrorMessage{
		Type: protocol.TypeInferenceError, RequestID: pr.RequestID,
		Error: "boom", StatusCode: 500,
	}

	pre := preCommitProviderErrorOutcome(pr, msg)
	if pre.PromptTokens != 0 || pre.CompletionTokens != 0 || pre.ReasoningTokens != 0 {
		t.Errorf("pre-commit legacy tokens = %d/%d/%d, want 0/0/0",
			pre.PromptTokens, pre.CompletionTokens, pre.ReasoningTokens)
	}
	if !pre.CompletionTokensSet {
		t.Error("error terminal must still force-persist completion_tokens=0 (existing behavior)")
	}

	post := postCommitProviderErrorOutcome(pr, msg)
	if post.CompletionTokensSet {
		t.Error("partial_success without usage must not force completion_tokens (existing behavior)")
	}
}

// End-to-end persistence through the memory store: an error-terminal outcome
// built from a usage-bearing message lands on the inference_routes row.
func TestAttemptUsagePersistsOnErrorRouteRow(t *testing.T) {
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	pr := &registry.PendingRequest{RequestID: "req-row", Model: "test-model", Attempt: 0}
	if err := st.RecordInferenceRoute(&store.InferenceRouteRecord{
		RequestID:  pr.RequestID,
		Attempt:    pr.Attempt,
		Model:      pr.Model,
		ProviderID: "prov-row",
	}); err != nil {
		t.Fatalf("RecordInferenceRoute: %v", err)
	}

	msg := attemptUsageErrMsg(pr.RequestID, &protocol.UsageInfo{PromptTokens: 123, CompletionTokens: 456, ReasoningTokens: 7})
	if err := st.UpdateInferenceRouteOutcome(pr.RequestID, pr.Attempt, postCommitProviderErrorOutcome(pr, msg)); err != nil {
		t.Fatalf("UpdateInferenceRouteOutcome: %v", err)
	}

	rec := findRouteRecord(st, pr.RequestID)
	if rec == nil {
		t.Fatal("route record not found")
	}
	if rec.FinalStatus != finalStatusPartialSuccess {
		t.Errorf("final_status = %q, want partial_success", rec.FinalStatus)
	}
	if rec.PromptTokens != 123 || rec.CompletionTokens != 456 || rec.ReasoningTokens != 7 {
		t.Errorf("persisted tokens = %d/%d/%d, want 123/456/7",
			rec.PromptTokens, rec.CompletionTokens, rec.ReasoningTokens)
	}
	if rec.CostMicroUSD != 0 {
		t.Errorf("cost_micro_usd = %d, want 0 (error terminals never bill from attempt usage)", rec.CostMicroUSD)
	}
}

// The consumer-gone (parked settlement) branch of handleInferenceError also
// persists attempt usage — and its refund behavior stays exactly as-is: the
// full reservation is refunded no matter what usage the terminal reported.
func TestConsumerGoneErrorPersistsAttemptUsageAndStillRefunds(t *testing.T) {
	srv, st, ledger := billingTestServer(t)
	srv.settleGrace = 5 * time.Second

	model := "attempt-usage-gone-model"
	provider := srv.registry.Register("attempt-usage-gone-provider", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
	})
	consumerID := testConsumerID
	balanceBefore := ledger.Balance(consumerID)
	const reserved int64 = 1_000_000
	if err := ledger.Charge(consumerID, reserved, "reserve:attempt-usage-gone"); err != nil {
		t.Fatalf("reserve balance: %v", err)
	}
	pr := &registry.PendingRequest{
		RequestID:        "attempt-usage-gone",
		Model:            model,
		ConsumerKey:      consumerID,
		ReservedMicroUSD: reserved,
	}
	if err := st.RecordInferenceRoute(&store.InferenceRouteRecord{
		RequestID:  pr.RequestID,
		Attempt:    pr.Attempt,
		Model:      model,
		ProviderID: provider.ID,
	}); err != nil {
		t.Fatalf("record route: %v", err)
	}
	parkConsumerGone(srv, provider, pr)

	msg := attemptUsageErrMsg(pr.RequestID, &protocol.UsageInfo{PromptTokens: 321, CompletionTokens: 654, ReasoningTokens: 9})
	srv.handleInferenceError(provider.ID, provider, &msg)

	// Route update and refund are async off the read loop; poll briefly.
	deadline := time.Now().Add(2 * time.Second)
	var rec *store.InferenceRouteRecord
	for time.Now().Before(deadline) {
		rec = findRouteRecord(st, pr.RequestID)
		if rec != nil && rec.FinalStatus != "" && ledger.Balance(consumerID) == balanceBefore {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if rec == nil || rec.FinalStatus == "" {
		t.Fatal("route outcome never finalized")
	}
	if rec.PromptTokens != 321 || rec.CompletionTokens != 654 || rec.ReasoningTokens != 9 {
		t.Errorf("persisted tokens = %d/%d/%d, want 321/654/9",
			rec.PromptTokens, rec.CompletionTokens, rec.ReasoningTokens)
	}
	if rec.CostMicroUSD != 0 {
		t.Errorf("cost_micro_usd = %d, want 0", rec.CostMicroUSD)
	}
	// ZERO billing change: full refund exactly as for a usage-less error.
	if got := ledger.Balance(consumerID); got != balanceBefore {
		t.Errorf("consumer balance = %d, want %d (full refund despite reported usage)", got, balanceBefore)
	}
	// A neutral typed cause on the parked path is health-neutral too.
	provider.Mu().Lock()
	failed := provider.Reputation.FailedJobs
	provider.Mu().Unlock()
	if failed != 0 {
		t.Errorf("FailedJobs = %d, want 0 (safety_deadline is not a provider fault)", failed)
	}
}
