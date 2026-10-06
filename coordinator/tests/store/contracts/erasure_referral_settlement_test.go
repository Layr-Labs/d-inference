package store_test

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/erasurefixture"
)

func TestErasedReferrerSettlementRefusesWithdrawableReward(t *testing.T) {
	for _, kind := range []string{"normal", "promotion"} {
		t.Run(kind, func(t *testing.T) {
			for name, s := range storeBackends(t) {
				t.Run(name, func(t *testing.T) {
					ctx := context.Background()
					referrer := erasurefixture.SeedAccount(t, s)
					var promotions store.ModelTokenPromotionStore
					if kind == "promotion" {
						promotions, _ = promotionFixture(t, s, 10)
					} else if err := s.CreateUser(&store.User{AccountID: "consumer", PrivyUserID: "did:privy:consumer"}); err != nil {
						t.Fatal(err)
					}
					seedConsumerReferral(t, s, "consumer", referrer.AccountID)
					if err := s.Credit("consumer", 100, store.LedgerDeposit, "seed"); err != nil {
						t.Fatal(err)
					}
					jobID := uniqueID("erased-referral")
					rewardReference := jobID
					if promotions != nil {
						rewardReference = "promotion:" + jobID
						if _, err := promotions.ReserveModelTokens(jobID, "consumer", "not-registered/model", 50, tokenPrice(50)); err != nil {
							t.Fatal(err)
						}
					}
					now := time.Now().UTC()
					req := erasurefixture.PlanAndConfirm(t, s, referrer, now, 0)
					if _, err := s.ScrubAccount(ctx, req.ID, now); err != nil {
						t.Fatal(err)
					}
					for attempt := 0; attempt < 2; attempt++ {
						var applied bool
						if promotions != nil {
							result, err := promotions.SettleModelTokenReservation(jobID, 50, tokenPrice(50), nil, true)
							if err != nil || result.Reservation.ConsumerCostMicroUSD != 40 || result.Reservation.SponsoredMicroUSD != 10 {
								t.Fatalf("promotion settlement = %+v, %v", result, err)
							}
							applied = result.Applied
						} else {
							result, err := s.FinalizeConsumerCharge(store.ConsumerChargeSettlement{AccountID: "consumer", JobID: jobID, CostMicroUSD: 40, ReferralEnabled: true})
							if err != nil || result.CollectedMicroUSD != 40 || result.ReferralRewardMicroUSD != 2 || result.Uncollected {
								t.Fatalf("normal settlement = %+v, %v", result, err)
							}
							applied = result.Applied
						}
						if applied != (attempt == 0) {
							t.Fatalf("attempt %d: applied = %v", attempt, applied)
						}
						if balance, withdrawable := s.GetBalance(referrer.AccountID), s.GetWithdrawableBalance(referrer.AccountID); balance != 0 || withdrawable != 0 {
							t.Fatalf("erased referrer balance = %d, withdrawable = %d; want zero", balance, withdrawable)
						}
						if balance := s.GetBalance("consumer"); balance != 60 {
							t.Fatalf("consumer balance = %d; want 60", balance)
						}
						refused, err := s.ListErasureRefusedCredits(ctx, referrer.AccountID)
						if err != nil || len(refused) != 1 {
							t.Fatalf("refused credits = %+v, %v; want one", refused, err)
						}
						if refused[0].EntryType != store.LedgerReferralReward || refused[0].AmountMicroUSD != 2 || refused[0].Reference != rewardReference {
							t.Fatalf("refused reward = %+v", refused[0])
						}
						var ledgerSum int64
						for _, entry := range s.LedgerHistory(referrer.AccountID) {
							ledgerSum += entry.AmountMicroUSD
							if entry.Type == store.LedgerReferralReward {
								t.Fatalf("refused reward reached ledger: %+v", entry)
							}
						}
						if ledgerSum != 0 {
							t.Fatalf("erased referrer ledger sum = %d; want zero", ledgerSum)
						}
					}
				})
			}
		})
	}
}
