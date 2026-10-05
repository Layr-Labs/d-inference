package inference_test

import (
	"errors"
	"fmt"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/promotions"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/reservations"

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

func (s *promotionSettlementFaultStore) SettleModelTokenReservation(id string, actual int64, quote store.ModelTokenQuote, earning *store.ModelTokenEarning, referralEligible bool) (store.ModelTokenSettlement, error) {
	first := s.calls.Add(1) == 1
	if first && s.beforeCommit {
		return store.ModelTokenSettlement{}, errors.New("temporary settlement outage")
	}
	result, err := s.ModelTokenPromotionStore.SettleModelTokenReservation(id, actual, quote, earning, referralEligible)
	if first && err == nil {
		return store.ModelTokenSettlement{}, errors.New("lost commit acknowledgement")
	}
	return result, err
}

func promotionCompletionRequest(s *reservationFixture, reservation *store.ModelTokenReservation, id string) (*registry.Provider, *registry.PendingRequest) {
	provider := s.registry.Register(id+"-provider", nil, &protocol.RegisterMessage{Models: []protocol.ModelInfo{{ID: promoTestModel}}})
	provider.Mu().Lock()
	provider.AccountID = "paid-provider"
	provider.Mu().Unlock()
	pr := &registry.PendingRequest{
		RequestID: id, Model: promoTestModel, PublicModel: "promotion-public-model", ConsumerKey: "promotion-user", KeyID: "promotion-key",
		ReservedMicroUSD: reservation.ReservedMicroUSD,
		ChunkCh:          make(chan registry.ProviderChunk, 1), CompleteCh: make(chan protocol.UsageInfo, 1), ErrorCh: make(chan protocol.InferenceErrorMessage, 1),
	}
	promotions.StampReservation(pr, reservation)
	provider.AddPending(pr)
	return provider, pr
}

func TestModelTokenPromotionReconciliationResumesAccountingOnce(t *testing.T) {
	for _, tc := range []struct {
		beforeCommit bool
		route        string
	}{
		{false, "public"}, {true, "public"},
		{false, "selected"}, {true, "selected"},
		{true, "self"}, {true, "prefer"}, {true, "free_self"}, {true, "owned"}, {true, "owned_paid"},
	} {
		beforeCommit := tc.beforeCommit
		name := "lost_commit_acknowledgement"
		if beforeCommit {
			name = "temporary_failure_before_commit"
		}
		t.Run(tc.route+"/"+name, func(t *testing.T) {
			s, st, r := promotionTestServer(t, 100)
			if err := st.SetModelPrice(store.ModelPrice{AccountID: "platform", Model: promoTestModel, InputPrice: 1_000_000, OutputPrice: 2_000_000}); err != nil {
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
			if tc.route == "owned_paid" {
				// Exhaust the grant so an unflagged owned-provider request remains
				// paid even though it still settles through the promotion contract.
				quote := func(int64) (int64, int64, error) { return 100, 0, nil }
				exhausted, err := st.ReserveModelTokens("exhaust-grant", "promotion-user", promoTestModel, 100, quote)
				if err != nil {
					t.Fatal(err)
				}
				if _, err := st.SettleModelTokenReservation(exhausted.ID, 100, quote, nil, false); err != nil {
					t.Fatal(err)
				}
			}
			w := httptest.NewRecorder()
			_, _, handled := s.reservations.Reserve(w, r, nil, reservations.Params{Model: promoTestModel, PublicModel: promoTestModel, BillingPromptTokens: 120, RequestedMaxTokens: 300})
			if handled {
				t.Fatal(w.Body)
			}
			provider, pr := promotionCompletionRequest(s, promotions.Reservation(r), "reconcile-accounting")
			switch tc.route {
			case "selected":
				pr.AllowedProviderSerials = []string{"selected-machine"}
			case "self":
				pr.SelfRouteOnly = true
			case "prefer":
				pr.PreferOwner = true
			case "free_self":
				pr.FreeSelfRoute = true
			case "owned", "owned_paid":
				provider.Mu().Lock()
				provider.AccountID = "promotion-user"
				provider.Mu().Unlock()
			}
			s.fault.useSettlement(&promotionSettlementFaultStore{Store: st, ModelTokenPromotionStore: st, beforeCommit: beforeCommit})
			s.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{RequestID: pr.RequestID, Usage: protocol.UsageInfo{PromptTokens: 100, CompletionTokens: 200}})
			// A retry must retain exclusion after the live request is cleaned up.
			pr.AllowedProviderSerials = nil
			pr.SelfRouteOnly, pr.PreferOwner, pr.FreeSelfRoute = false, false, false
			if len(s.ledger.Usage("promotion-user")) != 0 || st.GetBalance("platform") != 0 {
				t.Fatal("accounting ran before reconciliation")
			}
			// Referral rewards now commit with the consumer charge, even when
			// the acknowledgement needed for downstream accounting is lost.
			var reward, eligibleSpend int64
			if tc.route == "public" {
				reward, eligibleSpend = 20, 400
			}
			initialReward := reward
			if beforeCommit {
				initialReward = 0
			}
			if got := st.GetWithdrawableBalance("referrer"); got != initialReward {
				t.Fatalf("referral reward before reconciliation=%d want=%d", got, initialReward)
			}
			s.promotions.ReleaseRequest(r) // Must not refund an ambiguous commit.
			var attempted atomic.Bool
			var wg sync.WaitGroup
			for range 5 {
				wg.Add(1)
				go func() {
					defer wg.Done()
					pending, err := s.promotions.RetrySettlement(pr.ModelTokenReservationID)
					attempted.Store(pending)
					if err != nil {
						t.Error(err)
					}
				}()
			}
			wg.Wait()
			if !attempted.Load() {
				t.Fatal("settlement was not queued")
			}
			s.promotions.Maintain(time.Now())
			s.promotions.Maintain(time.Now())
			if pending, _ := s.promotions.RetrySettlement(pr.ModelTokenReservationID); pending {
				t.Fatal("settlement remained queued")
			}
			charged, payout, platform, usedTokens := int64(400), int64(400), int64(80), int64(100)
			if tc.route == "owned" {
				// Promotions already settle owned execution free and preserve grants.
				charged, payout, platform, usedTokens = 0, 0, 0, 0
			} else if tc.route == "owned_paid" {
				charged, payout, platform = 500, 400, 100
			}
			usage := s.ledger.Usage("promotion-user")
			if len(usage) != 1 || usage[0].CostMicroUSD != charged || usage[0].Model != "promotion-public-model" {
				t.Fatalf("session usage: %+v", usage)
			}
			deadline := time.Now().Add(2 * time.Second)
			for tc.route != "owned" && len(st.UsageRecords()) == 0 && time.Now().Before(deadline) {
				time.Sleep(time.Millisecond)
			}
			rows := st.UsageRecords()
			if tc.route == "owned" && len(rows) != 0 {
				t.Fatalf("owned execution leaked public usage: %+v", rows)
			}
			if tc.route != "owned" && (len(rows) != 1 || rows[0].CostMicroUSD != charged || rows[0].KeyID != pr.KeyID || rows[0].PublicModel != "promotion-public-model") {
				t.Fatalf("persistent usage: %+v", rows)
			}
			if spent := st.KeySpendSince(pr.KeyID, time.Time{}); spent != charged {
				t.Fatalf("key spend=%d", spent)
			}
			// Gross 500, consumer 400; provider 80% of gross, fee 20% of
			// collected spend, and a separately funded 5% referral reward.
			consumerBalance, publicProviderBalance := 1000-charged, payout
			if tc.route == "owned_paid" {
				consumerBalance += payout
				publicProviderBalance = 0
			}
			for account, want := range map[string]int64{"promotion-user": consumerBalance, "paid-provider": publicProviderBalance, "referrer": reward, "platform": platform} {
				if got := st.GetBalance(account); got != want {
					t.Errorf("%s balance=%d want=%d", account, got, want)
				}
			}
			stats, err := s.billing.Referral().Stats("referrer")
			if err != nil || stats.TotalReferredSpendMicroUSD != eligibleSpend || stats.TotalRewardsMicroUSD != reward {
				t.Fatalf("referral stats=%+v err=%v", stats, err)
			}
			grants, _ := st.ListModelTokenGrants("promotion-user")
			if grants[0].UsedTokens != usedTokens || grants[0].ReservedTokens != 0 {
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
				if err := st.SetModelPrice(store.ModelPrice{AccountID: "platform", Model: promoTestModel, InputPrice: 1_000_000, OutputPrice: 2_000_000}); err != nil {
					t.Fatal(err)
				}
				if err := st.CreditWithdrawable("promotion-user", 200, store.LedgerAdminCredit, "seed"); err != nil {
					t.Fatal(err)
				}
				w := httptest.NewRecorder()
				_, _, handled := s.reservations.Reserve(w, r, nil, reservations.Params{Model: promoTestModel, PublicModel: promoTestModel, BillingPromptTokens: 100, RequestedMaxTokens: 100})
				if handled {
					t.Fatal(w.Body)
				}
				provider, pr := promotionCompletionRequest(s, promotions.Reservation(r), "insufficient-settlement")
				output := 150 // Paid overage is within 2x cap, but there is no cash left.
				if priceIncrease {
					output = 100
					if err := st.SetModelPrice(store.ModelPrice{AccountID: "platform", Model: promoTestModel, InputPrice: 1_000_000, OutputPrice: 3_000_000}); err != nil {
						t.Fatal(err)
					}
				}
				if delayed {
					s.fault.useSettlement(&promotionSettlementFaultStore{Store: st, ModelTokenPromotionStore: st, beforeCommit: true})
				}
				s.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{RequestID: pr.RequestID, Usage: protocol.UsageInfo{PromptTokens: 100, CompletionTokens: output}})
				s.promotions.Maintain(time.Now())
				if pending, _ := s.promotions.RetrySettlement(pr.ModelTokenReservationID); pending {
					t.Fatal("deterministic failure is still retried")
				}
				if s.fault.renewing(pr.ModelTokenReservationID) {
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
		_, _, handled := s.reservations.Reserve(w, r, nil, reservations.Params{Model: promoTestModel, PublicModel: promoTestModel, BillingPromptTokens: 100, RequestedMaxTokens: 100})
		if handled {
			t.Fatal(w.Body)
		}
		provider, pr := promotionCompletionRequest(s, promotions.Reservation(r), id)
		s.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{RequestID: id, Usage: protocol.UsageInfo{}})
		s.promotions.Maintain(time.Now())
		if s.fault.renewing(pr.ModelTokenReservationID) {
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
