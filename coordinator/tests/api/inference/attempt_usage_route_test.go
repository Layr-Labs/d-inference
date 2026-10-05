package inference_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// The consumer-gone (parked settlement) branch of handleInferenceError also
// persists attempt usage — and its refund behavior stays exactly as-is: the
// full reservation is refunded no matter what usage the terminal reported.
func TestConsumerGoneErrorPersistsAttemptUsageAndStillRefunds(t *testing.T) {
	srv, st, ledger := billingTestServer(t)
	srv.late.Grace = 5 * time.Second

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
	srv.HandleInferenceError(provider.ID, provider, &msg)

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
