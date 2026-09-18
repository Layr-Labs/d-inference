package api

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/trial"
)

func bonsaiUnitPending(t *testing.T, s *Server, account string) (*registry.PendingRequest, *registry.Provider) {
	t.Helper()
	r := bonsaiUnitPrepared(t, s, bonsaiUnitRequest(trial.AuthSession, trial.ChatEndpoint, account))
	if err := s.reserveBonsaiTrial(r, trial.BonsaiBuildID, 1000); err != nil {
		t.Fatal(err)
	}
	provider := s.registry.Register("bonsai-settlement-provider", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: trial.BonsaiBuildID, ModelType: "chat", Quantization: "2bit"}},
	})
	provider.Mu().Lock()
	provider.AccountID = "bonsai-provider-account"
	provider.Mu().Unlock()
	pr := &registry.PendingRequest{RequestID: "bonsai-serving-attempt", ConsumerKey: account, Model: trial.BonsaiBuildID,
		PublicModel: "synthetic-bonsai-alias", TrialReservation: trialReservationFromRequest(r),
		TrialUnusedConfirmed: trialUnusedFromRequest(r),
		ChunkCh:              make(chan registry.ProviderChunk, 1), CompleteCh: make(chan protocol.UsageInfo, 1), ErrorCh: make(chan protocol.InferenceErrorMessage, 1)}
	if err := s.markTrialDispatched(pr, provider); err != nil {
		t.Fatal(err)
	}
	return pr, provider
}

func TestBonsaiTrialSettlementPaysProviderWithoutConsumerSpend(t *testing.T) {
	for _, account := range []string{"fresh-zero-balance", testConsumerID} {
		t.Run(account, func(t *testing.T) {
			s, st := bonsaiUnitServer(t)
			pr, provider := bonsaiUnitPending(t, s, account)
			before, withdrawableBefore := st.GetBalanceWithWithdrawable(account)
			usage := protocol.UsageInfo{PromptTokens: 2000, CompletionTokens: 500}
			wantCost, _ := s.bonsaiTrial.Rates.Cost(2000, 500)
			// A price update and campaign disable must not invalidate already
			// admitted work or change its provider compensation.
			s.bonsaiTrial.Enabled = false
			s.bonsaiTrial.Rates = trial.Rates{InputMicroUSDPerMillion: 9_000_000, OutputMicroUSDPerMillion: 9_000_000}
			if err := st.SetModelPrice("platform", pr.Model, 9_000_000, 9_000_000); err != nil {
				t.Fatal(err)
			}
			if !s.settleBonsaiTrial(pr, provider, usage, false) {
				t.Fatal("valid settlement failed")
			}
			if s.settleBonsaiTrial(pr, provider, usage, false) {
				t.Fatal("same request finalized twice")
			}
			// A reconstructed attempt has a fresh in-process finalizer. The
			// persisted logical ID still prevents a second quota use or payout.
			recovered := &registry.PendingRequest{RequestID: "recovered-attempt", ConsumerKey: account, Model: pr.Model, TrialReservation: pr.TrialReservation}
			s.settleBonsaiTrial(recovered, provider, usage, false)
			if balance, withdrawable := st.GetBalanceWithWithdrawable(account); balance != before || withdrawable != withdrawableBefore {
				t.Fatal("trial changed consumer funds")
			}
			if got := st.GetWithdrawableBalance(provider.AccountID); got != payments.ProviderPayout(wantCost) {
				t.Fatalf("provider credit=%d want=%d", got, payments.ProviderPayout(wantCost))
			}
			earnings, err := st.GetProviderEarnings(provider.PublicKey, 10)
			if err != nil || len(earnings) != 1 || earnings[0].JobID != pr.TrialReservation.ID {
				t.Fatalf("earnings=%+v err=%v", earnings, err)
			}
			records := st.UsageByConsumer(account)
			if len(records) != 1 || records[0].CostMicroUSD != 0 || records[0].KeyID != "" || records[0].PromptTokens != 2000 || records[0].CompletionTokens != 500 {
				t.Fatalf("consumer usage=%+v", records)
			}
			a, err := st.GetTrialAllowance(context.Background(), account, s.bonsaiTrial.CampaignID)
			if err != nil || a.UsedTokens != 2500 || a.ReservedTokens != 0 {
				t.Fatalf("allowance=%+v err=%v", a, err)
			}
		})
	}
}

func TestBonsaiTrialSettlementRetainsMalformedUsageHold(t *testing.T) {
	for _, usage := range []protocol.UsageInfo{{PromptTokens: -1, CompletionTokens: 10}, {PromptTokens: 10, CompletionTokens: -1}, {PromptTokens: 5097}} {
		s, st := bonsaiUnitServer(t)
		pr, provider := bonsaiUnitPending(t, s, "account")
		if s.settleBonsaiTrial(pr, provider, usage, false) {
			t.Fatalf("invalid usage accepted: %+v", usage)
		}
		r, err := st.GetTrialReservation(context.Background(), pr.TrialReservation.ID)
		if err != nil || r.State != store.TrialUnresolved {
			t.Fatalf("invalid usage lost hold: %+v, %v", r, err)
		}
		a, err := st.GetTrialAllowance(context.Background(), "account", s.bonsaiTrial.CampaignID)
		if err != nil || a.UsedTokens != 0 || a.ReservedTokens != 5096 {
			t.Fatalf("allowance=%+v err=%v", a, err)
		}
		if st.GetWithdrawableBalance(provider.AccountID) != 0 || len(st.UsageByConsumer("account")) != 0 {
			t.Fatal("invalid usage produced money or usage")
		}
		// Valid terminal evidence can resolve a retained hold exactly once.
		if !s.settleBonsaiTrial(pr, provider, protocol.UsageInfo{PromptTokens: 100, CompletionTokens: 10}, false) {
			t.Fatal("valid evidence failed to resolve hold")
		}
	}
}

func TestBonsaiTrialOwnedServiceReleasesWithoutQuotaOrPayout(t *testing.T) {
	s, st := bonsaiUnitServer(t)
	pr, provider := bonsaiUnitPending(t, s, "owner")
	provider.Mu().Lock()
	provider.AccountID = "owner"
	provider.Mu().Unlock()
	if !s.settleBonsaiTrial(pr, provider, protocol.UsageInfo{PromptTokens: 100, CompletionTokens: 10}, true) {
		t.Fatal("owned service did not settle")
	}
	a, err := st.GetTrialAllowance(context.Background(), "owner", s.bonsaiTrial.CampaignID)
	if err != nil || a.UsedTokens != 0 || a.ReservedTokens != 0 {
		t.Fatalf("owned service consumed quota: %+v, %v", a, err)
	}
	r, err := st.GetTrialReservation(context.Background(), pr.TrialReservation.ID)
	if err != nil || r.State != store.TrialReleased {
		t.Fatalf("owned hold not released: %+v, %v", r, err)
	}
	if st.GetWithdrawableBalance("owner") != 0 {
		t.Fatal("owned service manufactured an earning")
	}
}

func TestBonsaiTrialClientGonePartialCompletionPaysOnce(t *testing.T) {
	s, st := bonsaiUnitServer(t)
	s.settleGrace = time.Hour
	pr, provider := bonsaiUnitPending(t, s, "disconnected-consumer")
	parkConsumerGone(s, provider, pr)
	msg := &protocol.InferenceCompleteMessage{Type: protocol.TypeInferenceComplete, RequestID: pr.RequestID,
		Usage: protocol.UsageInfo{PromptTokens: 200, CompletionTokens: 15}}
	s.handleComplete(provider.ID, provider, msg)
	s.handleComplete(provider.ID, provider, msg)
	a, err := st.GetTrialAllowance(context.Background(), pr.ConsumerKey, s.bonsaiTrial.CampaignID)
	if err != nil || a.UsedTokens != 215 || a.ReservedTokens != 0 {
		t.Fatalf("disconnect accounting=%+v, %v", a, err)
	}
	if got := st.GetWithdrawableBalance(provider.AccountID); got != payments.MinimumCharge() {
		t.Fatalf("partial provider credit=%d", got)
	}
	if got := st.GetBalance(pr.ConsumerKey); got != 0 {
		t.Fatalf("disconnected consumer charged=%d", got)
	}
}

func TestBonsaiTrialDispatchRejectsConflictingProviderRate(t *testing.T) {
	for _, matching := range []bool{false, true} {
		s, st := bonsaiUnitServer(t)
		r := bonsaiUnitPrepared(t, s, bonsaiUnitRequest(trial.AuthSession, trial.ChatEndpoint, "account"))
		if err := s.reserveBonsaiTrial(r, trial.BonsaiBuildID, 100); err != nil {
			t.Fatal(err)
		}
		provider := &registry.Provider{ID: "provider", AccountID: "provider-account"}
		input := int64(999_000)
		if matching {
			input = 12_000
		}
		if err := st.SetModelPrice(providerPricingKeys(provider), trial.BonsaiBuildID, input, 47_000); err != nil {
			t.Fatal(err)
		}
		pr := &registry.PendingRequest{Model: trial.BonsaiBuildID, TrialReservation: trialReservationFromRequest(r), TrialUnusedConfirmed: trialUnusedFromRequest(r)}
		err := s.markTrialDispatched(pr, provider)
		if (err == nil) != matching {
			t.Fatalf("matching=%v dispatch error=%v", matching, err)
		}
		got, getErr := st.GetTrialReservation(r.Context(), pr.TrialReservation.ID)
		want := store.TrialReserved
		if matching {
			want = store.TrialDispatched
		}
		if getErr != nil || got.State != want {
			t.Fatalf("state=%s err=%v", got.State, getErr)
		}
	}
}

func TestBonsaiTrialFeeSnapshotMatchesPaidPolicy(t *testing.T) {
	for _, fee := range []int64{-1, 0, 25, 100, 101} {
		s, st := bonsaiUnitServer(t)
		pr, provider := bonsaiUnitPending(t, s, "account")
		// Freeze a policy in the request snapshot; settlement must honor the
		// same clamping and integer rounding as ordinary provider payments.
		pr.TrialReservation.PricingJSON, _ = json.Marshal(trialPriceSnapshot{Rates: s.bonsaiTrial.Rates, FeePercent: &fee})
		if !s.settleBonsaiTrial(pr, provider, protocol.UsageInfo{PromptTokens: 1, CompletionTokens: 1}, false) {
			t.Fatalf("fee=%d settlement failed", fee)
		}
		want := payments.ProviderPayoutWithPercent(payments.MinimumCharge(), &fee)
		if got := st.GetWithdrawableBalance(provider.AccountID); got != want {
			t.Fatalf("fee=%d credit=%d want=%d", fee, got, want)
		}
	}
}
