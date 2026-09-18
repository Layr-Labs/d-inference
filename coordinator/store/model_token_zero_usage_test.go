package store

import (
	"errors"
	"testing"
)

func TestModelTokenPromotionZeroUsageRejectsChargeAndPayout(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			b, _ := promotionFixture(t, s, 100)
			r, err := b.ReserveModelTokens("zero-usage", "consumer", "not-registered/model", 100, tokenPrice(100))
			// Reserve with a completely sponsored minimum price.
			if err != nil {
				t.Fatal(err)
			}
			for _, gross := range []int64{0, 100} {
				quote := func(int64) (int64, int64, error) { return gross, 0, nil }
				for _, payout := range []int64{0, 100} {
					if gross == 0 && payout == 0 {
						continue
					}
					earning := &ProviderEarning{AccountID: "provider", JobID: "zero-usage-job", AmountMicroUSD: payout}
					_, err := b.SettleModelTokenReservation(r.ID, 0, quote, earning)
					if !errors.Is(err, ErrPromotionInvalidSettlement) {
						t.Fatalf("gross=%d payout=%d: %v", gross, payout, err)
					}
				}
			}
			if s.GetBalance("provider") != 0 {
				t.Fatal("zero-usage provider was credited")
			}
			// A zero-cost owned request is still allowed to return its holds.
			result, err := b.SettleModelTokenReservation(r.ID, 0, tokenPrice(0), nil)
			if err != nil || !result.Applied {
				t.Fatalf("zero-cost settlement: %+v %v", result, err)
			}
			grants, _ := b.ListModelTokenGrants("consumer")
			if grants[0].RemainingTokens != 100 || grants[0].ReservedTokens != 0 {
				t.Fatal(grants)
			}
		})
	}
}
