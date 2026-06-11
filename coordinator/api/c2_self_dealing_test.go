package api

// Regression test for C2: a provider minting a withdrawable payout out of the
// consumer's own balance via self-dealing. Before the fix, the same-owner free
// settlement only ran for FreeSelfRoute/PreferOwner requests; a NORMAL paid
// request that happened to land on a provider owned by the requesting account
// settled PAID and credited that provider a withdrawable payout — letting an
// operator pay itself (and launder non-withdrawable invite credit into cashable
// balance). The fix evaluates same-owner free settlement for EVERY request.
//
// This test MUST fail without the fix and PASS with it.

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestC2_SameOwnerPaidRequestMintsNoPayout(t *testing.T) {
	srv, st, ledger := billingTestServer(t)

	const model = "c2-self-deal-model"
	// The SAME account is both the consumer and the owner of the serving
	// provider. testConsumerID is seeded with balance by the harness.
	acct := testConsumerID

	provider := srv.registry.Register("c2-prov", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
	})
	provider.Mu().Lock()
	provider.AccountID = acct // provider owned by the consumer's own account
	provider.Mu().Unlock()

	wdBefore := st.GetWithdrawableBalance(acct)

	// A plain PAID reservation — FreeSelfRoute / PreferOwner are intentionally
	// left false, which is exactly the path the pre-fix guard skipped.
	const reserve int64 = 1_000_000
	if err := ledger.Charge(acct, reserve, "reserve:c2"); err != nil {
		t.Fatal(err)
	}

	pr := &registry.PendingRequest{
		RequestID:        "c2-self-deal-req",
		Model:            model,
		ConsumerKey:      acct,
		ReservedMicroUSD: reserve,
		ChunkCh:          make(chan string, 1),
		CompleteCh:       make(chan protocol.UsageInfo, 1),
		ErrorCh:          make(chan protocol.InferenceErrorMessage, 1),
	}
	provider.AddPending(pr)

	// Provider reports inflated usage (the C2 lever). With the fix this is moot
	// because the request settles free; without it, this mints a payout.
	srv.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{
		Type:      protocol.TypeInferenceComplete,
		RequestID: pr.RequestID,
		Usage:     protocol.UsageInfo{PromptTokens: 10, CompletionTokens: 100_000},
	})

	// The serving provider is owned by the requesting account → the request must
	// settle FREE: no withdrawable payout may be minted.
	if wd := st.GetWithdrawableBalance(acct); wd != wdBefore {
		t.Errorf("same-owner paid request minted withdrawable payout: withdrawable %d -> %d (delta %d), want unchanged (free settlement)",
			wdBefore, wd, wd-wdBefore)
	}
}
