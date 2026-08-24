package api

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestValidCompletionUsage(t *testing.T) {
	valid := protocol.UsageInfo{
		PromptTokens:     10,
		CompletionTokens: 5,
		ReasoningTokens:  2,
	}
	if !validCompletionUsage(valid) {
		t.Fatal("valid usage was rejected")
	}

	for name, usage := range map[string]protocol.UsageInfo{
		"negative prompt": {
			PromptTokens: -1, CompletionTokens: 5,
		},
		"negative completion": {
			PromptTokens: 10, CompletionTokens: -1,
		},
		"negative reasoning": {
			PromptTokens: 10, CompletionTokens: 5, ReasoningTokens: -1,
		},
		"reasoning exceeds completion": {
			PromptTokens: 10, CompletionTokens: 5, ReasoningTokens: 6,
		},
	} {
		t.Run(name, func(t *testing.T) {
			if validCompletionUsage(usage) {
				t.Fatalf("invalid usage accepted: %+v", usage)
			}
		})
	}
}

func TestHandleCompleteRejectsInvalidUsageBeforeSettlement(t *testing.T) {
	srv, st, _ := billingTestServer(t)
	const (
		model     = "invalid-usage-model"
		accountID = "invalid-usage-provider-account"
	)
	provider := srv.registry.Register("invalid-usage-provider", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
	})
	provider.Mu().Lock()
	provider.AccountID = accountID
	provider.Mu().Unlock()

	pr := &registry.PendingRequest{
		RequestID:   "invalid-usage-request",
		Model:       model,
		ConsumerKey: testConsumerID,
		ChunkCh:     make(chan string, 1),
		CompleteCh:  make(chan protocol.UsageInfo, 1),
		ErrorCh:     make(chan protocol.InferenceErrorMessage, 1),
	}
	provider.AddPending(pr)

	srv.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{
		Type:      protocol.TypeInferenceComplete,
		RequestID: pr.RequestID,
		Usage: protocol.UsageInfo{
			PromptTokens:     -10,
			CompletionTokens: 5,
		},
	})

	got := <-pr.ErrorCh
	if got.FailureCode != protocol.FailureCodeGenerationFailure || got.StatusCode != 500 {
		t.Fatalf("error = %+v, want generation failure status 500", got)
	}
	if provider.GetPending(pr.RequestID) != nil {
		t.Fatal("invalid completion left request pending")
	}
	if provider.Reputation.SuccessfulJobs != 0 || provider.Reputation.FailedJobs != 1 {
		t.Fatalf("reputation = %+v, want one failed job and no successes", provider.Reputation)
	}
	if got := st.GetWithdrawableBalance(accountID); got != 0 {
		t.Fatalf("provider payout = %d, want 0", got)
	}
	earnings, err := st.GetAccountEarnings(accountID, 10)
	if err != nil {
		t.Fatalf("GetAccountEarnings: %v", err)
	}
	if len(earnings) != 0 {
		t.Fatalf("provider earnings = %+v, want none", earnings)
	}
}
