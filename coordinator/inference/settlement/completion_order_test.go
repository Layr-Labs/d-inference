package settlement

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// The observation boundary must retain the old placement between usage and
// referral/payout credits, including the live referral lookup after observation.
func TestCompletionObservationPrecedesCurrentReferralAndPayouts(t *testing.T) {
	svc, st, ledger := settlementTestService(t)
	const model, account, referrer = "observer-build", "observer-provider", "observer-referrer"
	feePercent := int64(20)
	if err := st.CreateUser(&store.User{AccountID: testConsumerID, PrivyUserID: "did:privy:observer", PlatformFeePercent: &feePercent}); err != nil {
		t.Fatal(err)
	}
	providers := registry.New(svc.deps.Logger)
	svc.deps.Providers = func() Providers { return providers }
	provider := providers.Register("observer-session", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: model, ModelType: "chat"}},
	})
	provider.Mu().Lock()
	provider.AccountID = account
	provider.Mu().Unlock()
	referrals := billing.NewReferralService(st, svc.deps.Logger, 20)
	if _, err := referrals.Register(referrer, "observer"); err != nil {
		t.Fatal(err)
	}
	if err := referrals.Apply(testConsumerID, "observer"); err != nil {
		t.Fatal(err)
	}
	var currentReferral Referral
	referralReads := 0
	svc.deps.Referral = func() Referral {
		referralReads++
		return currentReferral
	}
	usage := protocol.UsageInfo{PromptTokens: 1000, CompletionTokens: 500}
	cost := payments.CalculateCost(model, usage.PromptTokens, usage.CompletionTokens)
	initial := ledger.Balance(testConsumerID)
	if err := ledger.Charge(testConsumerID, cost*2, "reserve:observer"); err != nil {
		t.Fatal(err)
	}
	pr := &registry.PendingRequest{
		RequestID: "observer-complete", Model: model, PublicModel: "public-alias",
		ConsumerKey: testConsumerID, ReservedMicroUSD: cost * 2,
	}
	msg := &protocol.InferenceCompleteMessage{RequestID: pr.RequestID, Usage: usage}
	observations := 0
	observe := func(totalCost int64) {
		observations++
		entries := ledger.Usage(testConsumerID)
		if len(entries) != 1 || entries[0].Model != pr.PublicModel || entries[0].CostMicroUSD != cost {
			t.Fatalf("usage at observation = %+v, want the settled public-model entry", entries)
		}
		if totalCost != cost || ledger.Balance(testConsumerID) != initial-cost || !pr.IsReservationFinalized() {
			t.Fatal("observation ran before the consumer reservation was settled")
		}
		if st.GetWithdrawableBalance(account) != 0 || st.GetWithdrawableBalance(referrer) != 0 || st.GetBalance("platform") != 0 {
			t.Fatal("payout credits ran before the usage observation")
		}
		if referralReads != 0 {
			t.Fatal("referral configuration was read before the usage observation")
		}
		currentReferral = referrals
	}
	result := svc.Complete(provider.ID, provider, pr, msg, observe)
	fee := payments.PlatformFeeWithPercent(cost, &feePercent)
	reward := fee * referrals.SharePercent() / 100
	if reward <= 0 {
		t.Fatal("fixture must produce a nonzero referral reward")
	}
	if result.CostMicroUSD != cost || result.ProviderPayoutMicroUSD != payments.ProviderPayoutWithPercent(cost, &feePercent) {
		t.Fatalf("completion amounts = %+v, want cost %d and payout %d", result, cost, payments.ProviderPayoutWithPercent(cost, &feePercent))
	}
	if st.GetWithdrawableBalance(account) != result.ProviderPayoutMicroUSD || st.GetWithdrawableBalance(referrer) != reward || st.GetBalance("platform") != fee-reward {
		t.Fatal("completion did not use the referral configuration published at observation")
	}
	if observations != 1 || referralReads != 1 {
		t.Fatalf("observations=%d referral reads=%d, want one of each", observations, referralReads)
	}
	svc.Complete(provider.ID, provider, pr, msg, observe)
	if observations != 1 || referralReads != 1 || len(ledger.Usage(testConsumerID)) != 1 || st.GetWithdrawableBalance(account) != result.ProviderPayoutMicroUSD {
		t.Fatal("an already-finalized reservation repeated observation, usage or payout")
	}
}
