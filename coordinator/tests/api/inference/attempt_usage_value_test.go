package inference_test

import (
	"testing"

	routeoutcome "github.com/eigeninference/d-inference/coordinator/internal/inference/outcome"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

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
		{"post_commit", routeoutcome.PostCommitProviderErrorOutcome(pr, msg)},
		{"pre_response", routeoutcome.PreResponseProviderErrorOutcome(pr, msg)},
		{"pre_commit", routeoutcome.PreCommitProviderErrorOutcome(pr, msg)},
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
	if out := routeoutcome.PreCommitProviderErrorOutcome(pr, clientMsg); out.PromptTokens != 123 || out.CompletionTokens != 456 {
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
		FailureCode: protocol.FailureCodeGenerationFailure,
	}

	pre := routeoutcome.PreCommitProviderErrorOutcome(pr, msg)
	if pre.PromptTokens != 0 || pre.CompletionTokens != 0 || pre.ReasoningTokens != 0 {
		t.Errorf("pre-commit legacy tokens = %d/%d/%d, want 0/0/0",
			pre.PromptTokens, pre.CompletionTokens, pre.ReasoningTokens)
	}
	if !pre.CompletionTokensSet {
		t.Error("error terminal must still force-persist completion_tokens=0 (existing behavior)")
	}

	post := routeoutcome.PostCommitProviderErrorOutcome(pr, msg)
	if post.CompletionTokensSet {
		t.Error("partial_success without usage must not force completion_tokens (existing behavior)")
	}
}

// End-to-end persistence through the memory store: an error-terminal outcome
// built from a usage-bearing message lands on the inference_routes row.
func TestAttemptUsagePersistsOnErrorRouteRow(t *testing.T) {
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
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
	if err := st.UpdateInferenceRouteOutcome(pr.RequestID, pr.Attempt, routeoutcome.PostCommitProviderErrorOutcome(pr, msg)); err != nil {
		t.Fatalf("UpdateInferenceRouteOutcome: %v", err)
	}

	rec := findRouteRecord(st, pr.RequestID)
	if rec == nil {
		t.Fatal("route record not found")
	}
	if rec.FinalStatus != routeoutcome.FinalStatusPartialSuccess {
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
