package inference_test

import (
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/promotions"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type referralRetryStore struct {
	store.ModelTokenPromotionStore
	lostCommit  bool
	eligibility []bool
}

func (s *referralRetryStore) SettleModelTokenReservation(id string, actual int64, quote store.ModelTokenQuote, earning *store.ModelTokenEarning, eligible bool) (store.ModelTokenSettlement, error) {
	s.eligibility = append(s.eligibility, eligible)
	if len(s.eligibility) == 1 {
		if s.lostCommit {
			if _, err := s.ModelTokenPromotionStore.SettleModelTokenReservation(id, actual, quote, earning, eligible); err != nil {
				return store.ModelTokenSettlement{}, err
			}
		}
		return store.ModelTokenSettlement{}, errors.New("injected settlement failure")
	}
	return s.ModelTokenPromotionStore.SettleModelTokenReservation(id, actual, quote, earning, eligible)
}

func TestModelTokenReferralRetryCapturesEligibility(t *testing.T) {
	for _, eligible := range []bool{false, true} {
		for _, lostCommit := range []bool{false, true} {
			t.Run(fmt.Sprintf("eligible=%v/lostCommit=%v", eligible, lostCommit), func(t *testing.T) {
				s, st, _ := promotionTestServer(t, 10)
				if err := st.CreateReferrer("referrer", "referrer"); err != nil {
					t.Fatal(err)
				}
				if err := st.RecordReferral("referrer", "promotion-user"); err != nil {
					t.Fatal(err)
				}
				if err := st.Credit("promotion-user", 1000, store.LedgerDeposit, "seed"); err != nil {
					t.Fatal(err)
				}
				rates := payments.Rates{Input: 1_000_000, Output: 1_000_000}
				r, err := st.ReserveModelTokens("retry", "promotion-user", promoTestModel, 150, func(free int64) (int64, int64, error) {
					price, err := promotions.PriceTokens(150, 0, rates, free, nil)
					return price.Gross, price.Paid, err
				})
				if err != nil {
					t.Fatal(err)
				}
				pr := &registry.PendingRequest{RequestID: "retry", Model: promoTestModel, ConsumerKey: "promotion-user"}
				promotions.StampReservation(pr, r)
				fault := &referralRetryStore{ModelTokenPromotionStore: st, lostCommit: lostCommit}
				s.fault.useSettlement(fault)
				provider := &registry.Provider{ID: "provider", AccountID: "provider"}
				callbacks := 0
				_, _, _, err = s.promotions.Settle(pr, provider, protocol.UsageInfo{PromptTokens: 150}, rates, nil, false, eligible, func(cost int64) {
					callbacks++
					if cost != 140 {
						t.Errorf("callback cost=%d", cost)
					}
				})
				if err == nil {
					t.Fatal("missing injected failure")
				}
				// Retry must use the terminal decision, not re-read mutable routing/account state.
				pr.FreeSelfRoute, pr.SelfRouteOnly, pr.PreferOwner = true, true, true
				pr.AllowedProviderSerials = []string{"restricted"}
				provider.AccountID = "promotion-user"
				s.promotions.Maintain(time.Now())
				if len(fault.eligibility) != 2 || fault.eligibility[0] != eligible || fault.eligibility[1] != eligible || callbacks != 1 {
					t.Fatalf("eligibility=%v callbacks=%d", fault.eligibility, callbacks)
				}
				if attempted, err := s.promotions.RetrySettlement(r.ID); attempted || err != nil {
					t.Fatalf("completed retry remained queued: %v %v", attempted, err)
				}
				price, err := promotions.PriceTokens(150, 0, rates, 10, nil)
				if err != nil || st.GetBalance("promotion-user") != 860 || st.GetWithdrawableBalance("provider") != price.Payout {
					t.Fatalf("billing/provider payout changed: price=%+v err=%v", price, err)
				}
				stats, err := st.GetReferralStats("referrer")
				wantSpend, wantReward := int64(0), int64(0)
				if eligible {
					wantSpend, wantReward = 140, 7
				}
				if err != nil || stats.TotalReferredSpendMicroUSD != wantSpend || stats.TotalRewardsMicroUSD != wantReward || st.GetWithdrawableBalance("referrer") != wantReward {
					t.Fatalf("stats=%+v err=%v", stats, err)
				}
				grants, err := st.ListModelTokenGrants("promotion-user")
				if err != nil || len(grants) != 1 || grants[0].UsedTokens != 10 || grants[0].ReservedTokens != 0 {
					t.Fatalf("grants=%+v err=%v", grants, err)
				}
			})
		}
	}
}
