package store

import (
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func promotionFixture(t *testing.T, s Store, tokens int64) (ModelTokenPromotionStore, time.Time) {
	t.Helper()
	if err := s.CreateUser(&User{AccountID: "consumer", PrivyUserID: "did:privy:consumer"}); err != nil {
		t.Fatal(err)
	}
	b, ok := As[ModelTokenPromotionStore](s)
	if !ok {
		t.Fatal("missing promotion backend")
	}
	now := time.Now().UTC().Truncate(time.Second)
	if err := b.PutModelTokenPromotion(ModelTokenPromotion{ModelID: "not-registered/model", Tokens: tokens, ClaimStartsAt: now.Add(-time.Hour), ClaimEndsAt: promotionClaimEnd(now.Add(time.Hour)), SignupCutoffAt: now.Add(time.Hour), MaxClaims: 250, Enabled: true}); err != nil {
		t.Fatal(err)
	}
	if _, err := b.ClaimModelTokenPromotion("consumer", "not-registered/model", now); err != nil {
		t.Fatal(err)
	}
	return b, now
}

func tokenPrice(tokens int64) ModelTokenQuote {
	return func(free int64) (int64, int64, error) { return tokens, max(tokens-free, 0), nil }
}

func TestModelTokenPromotionClaimWindowAndImmutability(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			b, now := promotionFixture(t, s, 150_000_000)
			for i := 0; i < 4; i++ {
				grants, err := b.ClaimModelTokenPromotion("consumer", "not-registered/model", now.Add(time.Duration(i)*24*time.Hour))
				if err != nil || len(grants) != 1 || grants[0].RemainingTokens != 150_000_000 {
					t.Fatalf("claim: %+v %v", grants, err)
				}
			}
			if err := s.CreateUser(&User{AccountID: "late", PrivyUserID: "did:privy:late"}); err != nil {
				t.Fatal(err)
			}
			for _, at := range []time.Time{now.Add(-2 * time.Hour), now.Add(time.Hour)} {
				grants, err := b.ClaimModelTokenPromotion("late", "not-registered/model", at)
				if !errors.Is(err, ErrPromotionUnavailable) || len(grants) != 0 {
					t.Fatalf("outside window: %+v %v", grants, err)
				}
			}
			promotions, err := b.ListModelTokenPromotions()
			if err != nil {
				t.Fatal(err)
			}
			p := promotions[0]
			p.Enabled = false
			if err = b.PutModelTokenPromotion(p); err != nil {
				t.Fatal(err)
			}
			grants, err := b.ClaimModelTokenPromotion("late", "not-registered/model", now)
			if !errors.Is(err, ErrPromotionUnavailable) || len(grants) != 0 {
				t.Fatal("disabled promotion granted tokens")
			}
			p.Tokens++
			if err = b.PutModelTokenPromotion(p); !errors.Is(err, ErrPromotionConflict) {
				t.Fatalf("mutable terms: %v", err)
			}
			if err := s.CreateUser(&User{AccountID: "service", PrivyUserID: "did:privy:service", Role: RoleService}); err != nil {
				t.Fatal(err)
			}
			if _, err = b.ClaimModelTokenPromotion("service", "not-registered/model", now); !errors.Is(err, ErrPromotionIneligible) {
				t.Fatalf("service grant: %v", err)
			}
		})
	}
}

func TestModelTokenPromotionSettlementPaysProviderAtomically(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			b, _ := promotionFixture(t, s, 100)
			r, err := b.ReserveModelTokens("r1", "consumer", "not-registered/model", 80, tokenPrice(80))
			if err != nil || r.FreeTokens != 80 || r.ReservedMicroUSD != 0 {
				t.Fatalf("reserve: %+v %v", r, err)
			}
			earning := &ModelTokenEarning{ProviderEarning: ProviderEarning{AccountID: "provider", ProviderID: "p", ProviderKey: "pk", JobID: "job", Model: r.ModelID, AmountMicroUSD: 30, PromptTokens: 20, CompletionTokens: 10}}
			result, err := b.SettleModelTokenReservation(r.ID, 30, tokenPrice(30), earning)
			if err != nil || !result.Applied || result.Reservation.ConsumerCostMicroUSD != 0 || result.Reservation.SponsoredMicroUSD != 30 {
				t.Fatalf("settle: %+v %v", result, err)
			}
			if s.GetBalance("consumer") != 0 || s.GetWithdrawableBalance("provider") != 30 {
				t.Fatal("free consumer/provider balance mismatch")
			}
			result, err = b.SettleModelTokenReservation(r.ID, 30, tokenPrice(30), earning)
			if err != nil || result.Applied {
				t.Fatal("settlement replay was not idempotent")
			}
			if released, err := b.ReleaseModelTokenReservation(r.ID); err != nil || released {
				t.Fatal("settled request refunded")
			}
			grants, _ := b.ListModelTokenGrants("consumer")
			if grants[0].RemainingTokens != 70 || grants[0].ReservedTokens != 0 {
				t.Fatalf("grant: %+v", grants)
			}
			if s.GetBalance("provider") != 30 {
				t.Fatal("provider paid twice")
			}
		})
	}
}

func TestModelTokenPromotionPartialPaidAndExhaustion(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			b, _ := promotionFixture(t, s, 10)
			if err := s.Credit("consumer", 100, LedgerAdminCredit, "seed"); err != nil {
				t.Fatal(err)
			}
			r, err := b.ReserveModelTokens("partial", "consumer", "not-registered/model", 20, tokenPrice(20))
			if err != nil || r.FreeTokens != 10 || s.GetBalance("consumer") != 90 {
				t.Fatalf("reserve %+v %v", r, err)
			}
			result, err := b.SettleModelTokenReservation(r.ID, 15, tokenPrice(15), &ModelTokenEarning{ProviderEarning: ProviderEarning{AccountID: "provider", JobID: "partial-job", AmountMicroUSD: 15}})
			if err != nil || result.Reservation.UsedTokens != 10 || result.Reservation.ConsumerCostMicroUSD != 5 {
				t.Fatalf("settle %+v %v", result, err)
			}
			if s.GetBalance("consumer") != 95 || s.GetBalance("provider") != 15 {
				t.Fatal("partial balances")
			}
			r, err = b.ReserveModelTokens("paid", "consumer", "not-registered/model", 20, tokenPrice(20))
			if err != nil || r.FreeTokens != 0 || r.ReservedMicroUSD != 20 {
				t.Fatalf("paid fallback %+v %v", r, err)
			}
			if _, err = b.ReleaseModelTokenReservation(r.ID); err != nil {
				t.Fatal(err)
			}
			if s.GetBalance("consumer") != 95 {
				t.Fatal("paid fallback refund")
			}
			if _, err = b.ReserveModelTokens("unfunded", "consumer", "not-registered/model", 200, tokenPrice(200)); !errors.Is(err, ErrInsufficientBalance) {
				t.Fatalf("exhausted fallback: %v", err)
			}
			if r, err = b.ReserveModelTokens("other", "consumer", "other-model", 20, tokenPrice(20)); err != nil || r != nil {
				t.Fatal("promotion leaked to another model")
			}
		})
	}
}

func TestModelTokenPromotionConcurrentClaimsReservationsAndTerminals(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			b, now := promotionFixture(t, s, 100)
			var wg sync.WaitGroup
			var admitted atomic.Int64
			ids := make(chan string, 24)
			for i := 0; i < 24; i++ {
				wg.Add(1)
				go func(i int) {
					defer wg.Done()
					if _, err := b.ClaimModelTokenPromotion("consumer", "not-registered/model", now); err != nil {
						t.Error(err)
						return
					}
					id := fmt.Sprintf("race-%d", i)
					r, err := b.ReserveModelTokens(id, "consumer", "not-registered/model", 10, tokenPrice(10))
					if err == nil {
						admitted.Add(1)
						ids <- r.ID
					} else if !errors.Is(err, ErrInsufficientBalance) {
						t.Error(err)
					}
				}(i)
			}
			wg.Wait()
			close(ids)
			if admitted.Load() != 10 {
				t.Fatalf("admitted %d, want 10", admitted.Load())
			}
			for id := range ids {
				wg.Add(2)
				go func(id string) {
					defer wg.Done()
					_, err := b.ReleaseModelTokenReservation(id)
					if err != nil {
						t.Error(err)
					}
				}(id)
				go func(id string) {
					defer wg.Done()
					_, err := b.SettleModelTokenReservation(id, 10, tokenPrice(10), &ModelTokenEarning{ProviderEarning: ProviderEarning{AccountID: "provider", JobID: id, AmountMicroUSD: 10}})
					if err != nil {
						t.Error(err)
					}
				}(id)
			}
			wg.Wait()
			grants, _ := b.ListModelTokenGrants("consumer")
			if grants[0].ReservedTokens != 0 || grants[0].UsedTokens+grants[0].RemainingTokens != 100 || s.GetBalance("provider") != grants[0].UsedTokens {
				t.Fatalf("terminal race: %+v provider=%d", grants, s.GetBalance("provider"))
			}
		})
	}
}

func TestModelTokenPromotionTopUpAndFailedSettlementRollback(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			b, _ := promotionFixture(t, s, 100)
			r, err := b.ReserveModelTokens("media", "consumer", "not-registered/model", 20, tokenPrice(20))
			if err != nil {
				t.Fatal(err)
			}
			r, err = b.TopUpModelTokenReservation(r.ID, 80, tokenPrice(80))
			if err != nil || r.FreeTokens != 80 || r.ReservedMicroUSD != 0 {
				t.Fatalf("media topup %+v %v", r, err)
			}
			if _, err = b.TopUpModelTokenReservation(r.ID, 120, tokenPrice(120)); !errors.Is(err, ErrInsufficientBalance) {
				t.Fatalf("topup should fail: %v", err)
			}
			grants, _ := b.ListModelTokenGrants("consumer")
			if grants[0].ReservedTokens != 80 {
				t.Fatal("failed topup consumed tokens")
			}
			_, err = b.SettleModelTokenReservation(r.ID, 1000, tokenPrice(1000), &ModelTokenEarning{ProviderEarning: ProviderEarning{AccountID: "provider", JobID: "bad", AmountMicroUSD: 1000}})
			if err == nil {
				t.Fatal("unbounded settlement accepted")
			}
			if s.GetBalance("provider") != 0 {
				t.Fatal("failed settlement credited provider")
			}
			if _, err = b.ReleaseModelTokenReservation(r.ID); err != nil {
				t.Fatal(err)
			}
			grants, _ = b.ListModelTokenGrants("consumer")
			if grants[0].RemainingTokens != 100 {
				t.Fatalf("failed operation lost grant: %+v", grants)
			}
		})
	}
}

func TestModelTokenPromotionOrphanRecoveryDoesNotReleaseLiveOrSettledRequests(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			b, _ := promotionFixture(t, s, 100)
			if err := s.Credit("consumer", 100, LedgerAdminCredit, "seed"); err != nil {
				t.Fatal(err)
			}
			old, err := b.ReserveModelTokens("orphan", "consumer", "not-registered/model", 120, tokenPrice(120))
			if err != nil {
				t.Fatal(err)
			}
			now := time.Now().Add(20 * time.Minute)
			// A healthy owner renews even while a long generation is in progress.
			if err = b.RenewModelTokenReservations([]string{old.ID}, now); err != nil {
				t.Fatal(err)
			}
			if n, err := b.ReleaseStaleModelTokenReservations(now.Add(-10 * time.Minute)); err != nil || n != 0 {
				t.Fatalf("live hold reclaimed: %d %v", n, err)
			}
			// A disappeared owner's holds return both free tokens and paid cash.
			if n, err := b.ReleaseStaleModelTokenReservations(now.Add(time.Minute)); err != nil || n != 1 {
				t.Fatalf("orphan not reclaimed: %d %v", n, err)
			}
			if s.GetBalance("consumer") != 100 {
				t.Fatal("orphan paid hold was not refunded")
			}
			grants, _ := b.ListModelTokenGrants("consumer")
			if grants[0].RemainingTokens != 100 {
				t.Fatal(grants)
			}
			result, err := b.SettleModelTokenReservation(old.ID, 10, tokenPrice(10), &ModelTokenEarning{ProviderEarning: ProviderEarning{AccountID: "provider", JobID: "late", AmountMicroUSD: 10}})
			if err != nil || result.Applied || s.GetBalance("provider") != 0 {
				t.Fatal("late terminal revived orphan")
			}
			if err = b.RenewModelTokenReservations([]string{old.ID}, now.Add(time.Hour)); err != nil {
				t.Fatal(err)
			}
			if n, err := b.ReleaseStaleModelTokenReservations(now.Add(2 * time.Hour)); err != nil || n != 0 {
				t.Fatal("recovered twice", n, err)
			}
		})
	}
}

func TestModelTokenPromotionRefundPreservesWithdrawableFunds(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			b, _ := promotionFixture(t, s, 10)
			if err := s.CreditWithdrawable("consumer", 100, LedgerPayout, "earned"); err != nil {
				t.Fatal(err)
			}
			r, err := b.ReserveModelTokens("earned-hold", "consumer", "not-registered/model", 30, tokenPrice(30))
			if err != nil || r.ReservedWithdrawableMicroUSD != 20 {
				t.Fatalf("hold %+v %v", r, err)
			}
			if s.GetWithdrawableBalance("consumer") != 80 {
				t.Fatal("withdrawable hold not protected")
			}
			_, err = b.SettleModelTokenReservation(r.ID, 15, tokenPrice(15), nil)
			if err != nil {
				t.Fatal(err)
			}
			if balance, withdrawable := s.GetBalanceWithWithdrawable("consumer"); balance != 95 || withdrawable != 95 {
				t.Fatalf("partial refund lost withdrawability: %d %d", balance, withdrawable)
			}
			r, err = b.ReserveModelTokens("cancel-earned", "consumer", "not-registered/model", 20, tokenPrice(20))
			if err != nil {
				t.Fatal(err)
			}
			if _, err = b.TopUpModelTokenReservation(r.ID, 0, tokenPrice(30)); err != nil {
				t.Fatal(err)
			}
			if _, err = b.ReleaseModelTokenReservation(r.ID); err != nil {
				t.Fatal(err)
			}
			if balance, withdrawable := s.GetBalanceWithWithdrawable("consumer"); balance != 95 || withdrawable != 95 {
				t.Fatalf("cancel refund lost withdrawability: %d %d", balance, withdrawable)
			}
		})
	}
}

func promotionClaimEnd(at time.Time) *time.Time { return &at }
