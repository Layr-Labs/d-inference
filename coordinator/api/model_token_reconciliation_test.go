package api

import (
	"errors"
	"fmt"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type promotionSettlementFaultStore struct {
	store.Store
	store.ModelTokenPromotionStore
	beforeCommit bool
	calls        atomic.Int64
}

func (s *promotionSettlementFaultStore) SettleModelTokenReservation(id string, actual int64, quote store.ModelTokenQuote, earning *store.ModelTokenEarning) (store.ModelTokenSettlement, error) {
	first := s.calls.Add(1) == 1
	if first && s.beforeCommit {
		return store.ModelTokenSettlement{}, errors.New("temporary settlement outage")
	}
	result, err := s.ModelTokenPromotionStore.SettleModelTokenReservation(id, actual, quote, earning)
	if first && err == nil {
		return store.ModelTokenSettlement{}, errors.New("lost commit acknowledgement")
	}
	return result, err
}

func promotionCompletionRequest(s *Server, reservation *store.ModelTokenReservation, id string) (*registry.Provider, *registry.PendingRequest) {
	provider := s.registry.Register(id+"-provider", nil, &protocol.RegisterMessage{Models: []protocol.ModelInfo{{ID: promoTestModel}}})
	provider.Mu().Lock()
	provider.AccountID = "paid-provider"
	provider.Mu().Unlock()
	pr := &registry.PendingRequest{
		RequestID: id, Model: promoTestModel, PublicModel: "promotion-public-model", ConsumerKey: "promotion-user", KeyID: "promotion-key",
		ReservedMicroUSD: reservation.ReservedMicroUSD,
		ChunkCh:          make(chan registry.ProviderChunk, 1), CompleteCh: make(chan protocol.UsageInfo, 1), ErrorCh: make(chan protocol.InferenceErrorMessage, 1),
	}
	stampModelTokenReservation(pr, reservation)
	provider.AddPending(pr)
	return provider, pr
}

func TestModelTokenPromotionReconciliationResumesAccountingOnce(t *testing.T) {
	for _, beforeCommit := range []bool{false, true} {
		name := "lost_commit_acknowledgement"
		if beforeCommit {
			name = "temporary_failure_before_commit"
		}
		t.Run(name, func(t *testing.T) {
			s, st, r := promotionTestServer(t, 100)
			if err := st.SetModelPrice("platform", promoTestModel, 1_000_000, 2_000_000); err != nil {
				t.Fatal(err)
			}
			if err := st.Credit("promotion-user", 1000, store.LedgerAdminCredit, "seed"); err != nil {
				t.Fatal(err)
			}
			fee := int64(20)
			if err := s.store.SetUserPlatformFeePercent("promotion-user", &fee); err != nil {
				t.Fatal(err)
			}
			if _, err := s.billing.Referral().Register("referrer", "PROMO"); err != nil {
				t.Fatal(err)
			}
			if err := s.billing.Referral().Apply("promotion-user", "PROMO"); err != nil {
				t.Fatal(err)
			}
			w := httptest.NewRecorder()
			_, _, handled := s.reserveInferenceBalance(w, r, nil, balanceReservationParams{model: promoTestModel, publicModel: promoTestModel, billingPromptTokens: 120, requestedMaxTokens: 300})
			if handled {
				t.Fatal(w.Body)
			}
			provider, pr := promotionCompletionRequest(s, modelTokenReservation(r), "reconcile-accounting")
			s.store = &promotionSettlementFaultStore{Store: st, ModelTokenPromotionStore: st, beforeCommit: beforeCommit}
			s.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{RequestID: pr.RequestID, Usage: protocol.UsageInfo{PromptTokens: 100, CompletionTokens: 200}})
			if len(s.ledger.Usage("promotion-user")) != 0 || st.GetBalance("platform") != 0 {
				t.Fatal("accounting ran before reconciliation")
			}
			// Referral credit commits with the consumer charge, even when the
			// acknowledgement is lost. Downstream accounting still waits.
			wantReward := int64(20)
			if beforeCommit {
				wantReward = 0
			}
			if got := st.GetWithdrawableBalance("referrer"); got != wantReward {
				t.Fatalf("committed referral reward=%d want=%d", got, wantReward)
			}
			retry, pending := s.modelTokenSettlements.Load(pr.ModelTokenReservationID)
			if !pending {
				t.Fatal("settlement was not queued")
			}
			s.releaseModelTokenRequest(r) // Must not refund an ambiguous commit.
			var wg sync.WaitGroup
			for range 5 {
				wg.Add(1)
				go func() {
					defer wg.Done()
					if err := retry.(func() error)(); err != nil {
						t.Error(err)
					}
				}()
			}
			wg.Wait()
			s.maintainModelTokens(st, time.Now())
			s.maintainModelTokens(st, time.Now())
			if _, pending := s.modelTokenSettlements.Load(pr.ModelTokenReservationID); pending {
				t.Fatal("settlement remained queued")
			}
			usage := s.ledger.Usage("promotion-user")
			if len(usage) != 1 || usage[0].CostMicroUSD != 400 || usage[0].Model != "promotion-public-model" {
				t.Fatalf("session usage: %+v", usage)
			}
			deadline := time.Now().Add(2 * time.Second)
			for len(st.UsageRecords()) == 0 && time.Now().Before(deadline) {
				time.Sleep(time.Millisecond)
			}
			rows := st.UsageRecords()
			if len(rows) != 1 || rows[0].CostMicroUSD != 400 || rows[0].KeyID != pr.KeyID || rows[0].PublicModel != "promotion-public-model" {
				t.Fatalf("persistent usage: %+v", rows)
			}
			if spent := st.KeySpendSince(pr.KeyID, time.Time{}); spent != 400 {
				t.Fatalf("key spend=%d", spent)
			}
			// Gross 500, consumer 400; provider 80% of gross, fee 20% of
			// collected spend, plus a separately funded 5% referral reward.
			for account, want := range map[string]int64{"promotion-user": 600, "paid-provider": 400, "referrer": 20, "platform": 80} {
				if got := st.GetBalance(account); got != want {
					t.Errorf("%s balance=%d want=%d", account, got, want)
				}
			}
			grants, _ := st.ListModelTokenGrants("promotion-user")
			if grants[0].UsedTokens != 100 || grants[0].ReservedTokens != 0 {
				t.Fatal(grants)
			}
		})
	}
}

func TestModelTokenPromotionInsufficientSettlementClosesHolds(t *testing.T) {
	for _, delayed := range []bool{false, true} {
		for _, priceIncrease := range []bool{false, true} {
			t.Run(fmt.Sprintf("retry=%t/price_increase=%t", delayed, priceIncrease), func(t *testing.T) {
				s, st, r := promotionTestServer(t, 100)
				if err := st.SetModelPrice("platform", promoTestModel, 1_000_000, 2_000_000); err != nil {
					t.Fatal(err)
				}
				if err := st.CreditWithdrawable("promotion-user", 200, store.LedgerAdminCredit, "seed"); err != nil {
					t.Fatal(err)
				}
				w := httptest.NewRecorder()
				_, _, handled := s.reserveInferenceBalance(w, r, nil, balanceReservationParams{model: promoTestModel, publicModel: promoTestModel, billingPromptTokens: 100, requestedMaxTokens: 100})
				if handled {
					t.Fatal(w.Body)
				}
				provider, pr := promotionCompletionRequest(s, modelTokenReservation(r), "insufficient-settlement")
				output := 150 // Paid overage is within 2x cap, but there is no cash left.
				if priceIncrease {
					output = 100
					if err := st.SetModelPrice("platform", promoTestModel, 1_000_000, 3_000_000); err != nil {
						t.Fatal(err)
					}
				}
				if delayed {
					s.store = &promotionSettlementFaultStore{Store: st, ModelTokenPromotionStore: st, beforeCommit: true}
				}
				s.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{RequestID: pr.RequestID, Usage: protocol.UsageInfo{PromptTokens: 100, CompletionTokens: output}})
				s.maintainModelTokens(st, time.Now())
				if _, pending := s.modelTokenSettlements.Load(pr.ModelTokenReservationID); pending {
					t.Fatal("deterministic failure is still retried")
				}
				if _, active := s.modelTokenActive.Load(pr.ModelTokenReservationID); active {
					t.Fatal("failed hold is still renewed")
				}
				grants, _ := st.ListModelTokenGrants("promotion-user")
				if grants[0].RemainingTokens != 100 || grants[0].ReservedTokens != 0 {
					t.Fatal(grants)
				}
				if st.GetBalance("promotion-user") != 200 || st.GetWithdrawableBalance("promotion-user") != 200 {
					t.Fatal("cash hold was not refunded")
				}
				if st.GetBalance("paid-provider") != 0 || len(s.ledger.Usage("promotion-user")) != 0 {
					t.Fatal("failed settlement produced earnings or charged usage")
				}
			})
		}
	}
}

func TestModelTokenPromotionZeroUsageCannotMintPayouts(t *testing.T) {
	s, st, r := promotionTestServer(t, 1000)
	for _, id := range []string{"zero-first", "zero-repeat"} {
		w := httptest.NewRecorder()
		_, _, handled := s.reserveInferenceBalance(w, r, nil, balanceReservationParams{model: promoTestModel, publicModel: promoTestModel, billingPromptTokens: 100, requestedMaxTokens: 100})
		if handled {
			t.Fatal(w.Body)
		}
		provider, pr := promotionCompletionRequest(s, modelTokenReservation(r), id)
		s.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{RequestID: id, Usage: protocol.UsageInfo{}})
		s.maintainModelTokens(st, time.Now())
		if _, active := s.modelTokenActive.Load(pr.ModelTokenReservationID); active {
			t.Fatal("zero-usage hold was not closed")
		}
	}
	if st.GetBalance("paid-provider") != 0 || st.GetBalance("promotion-user") != 0 {
		t.Fatal("zero usage moved money")
	}
	if len(s.ledger.Usage("promotion-user")) != 0 {
		t.Fatal("invalid terminal produced billable usage")
	}
	grants, _ := st.ListModelTokenGrants("promotion-user")
	if grants[0].RemainingTokens != 1000 || grants[0].ReservedTokens != 0 {
		t.Fatal(grants)
	}
}
