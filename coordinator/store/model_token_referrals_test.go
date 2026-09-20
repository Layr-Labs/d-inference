package store

import (
	"math"
	"sync"
	"testing"
)

func TestModelTokenReferralPaidPortionAndReplay(t *testing.T) {
	for _, tc := range []struct {
		name         string
		tokens, paid int64
		sameProvider bool
	}{
		{"free", 10, 0, false}, {"mixed", 50, 40, false}, {"provider_is_referrer", 50, 40, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			for name, s := range storeBackends(t) {
				t.Run(name, func(t *testing.T) {
					b, _ := promotionFixture(t, s, 10)
					seedConsumerReferral(t, s, "consumer", "referrer")
					if err := s.Credit("consumer", 100, LedgerDeposit, "seed"); err != nil {
						t.Fatal(err)
					}
					r, err := b.ReserveModelTokens("referral", "consumer", "not-registered/model", tc.tokens, tokenPrice(tc.tokens))
					if err != nil {
						t.Fatal(err)
					}
					provider := "provider"
					if tc.sameProvider {
						provider = "referrer"
					}
					earning := &ModelTokenEarning{ProviderEarning: ProviderEarning{AccountID: provider, JobID: r.ID, AmountMicroUSD: tc.tokens}}
					var wg sync.WaitGroup
					for range 8 {
						wg.Add(1)
						go func() {
							defer wg.Done()
							if _, err := b.SettleModelTokenReservation(r.ID, tc.tokens, tokenPrice(tc.tokens), earning); err != nil {
								t.Error(err)
							}
						}()
					}
					wg.Wait()
					if got := s.GetBalance("consumer"); got != 100-tc.paid {
						t.Fatalf("consumer=%d", got)
					}
					want := tc.paid / 20
					if tc.sameProvider {
						want += tc.tokens
					}
					if got := s.GetWithdrawableBalance("referrer"); got != want {
						t.Fatalf("referrer=%d want=%d", got, want)
					}
					stats, err := s.GetReferralStats("referrer")
					if err != nil || stats.TotalReferredSpendMicroUSD != tc.paid || stats.TotalRewardsMicroUSD != tc.paid/20 {
						t.Fatalf("stats=%+v err=%v", stats, err)
					}
				})
			}
		})
	}
}

func TestModelTokenReferralRollbackAndLateAttribution(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			b, _ := promotionFixture(t, s, 10)
			if err := s.Credit("consumer", 100, LedgerDeposit, "seed"); err != nil {
				t.Fatal(err)
			}
			r, err := b.ReserveModelTokens("late", "consumer", "not-registered/model", 50, tokenPrice(50))
			if err != nil {
				t.Fatal(err)
			}
			if _, err = b.SettleModelTokenReservation(r.ID, 50, tokenPrice(50), nil); err != nil {
				t.Fatal(err)
			}
			seedConsumerReferral(t, s, "consumer", "referrer")
			if _, err = b.SettleModelTokenReservation(r.ID, 50, tokenPrice(50), nil); err != nil {
				t.Fatal(err)
			}
			if s.GetBalance("referrer") != 0 {
				t.Fatal("retroactive reward")
			}
			r, err = b.ReserveModelTokens("overflow", "consumer", "not-registered/model", 40, tokenPrice(40))
			if err != nil {
				t.Fatal(err)
			}
			if err = s.Credit("referrer", math.MaxInt64, LedgerDeposit, "overflow"); err != nil {
				t.Fatal(err)
			}
			earning := &ModelTokenEarning{ProviderEarning: ProviderEarning{AccountID: "provider", JobID: r.ID, AmountMicroUSD: 30}}
			if _, err = b.SettleModelTokenReservation(r.ID, 30, tokenPrice(30), earning); err == nil {
				t.Fatal("overflow accepted")
			}
			if s.GetBalance("consumer") != 20 || s.GetBalance("provider") != 0 {
				t.Fatal("partial settlement")
			}
			if err = s.Debit("referrer", math.MaxInt64, LedgerCharge, "clear"); err != nil {
				t.Fatal(err)
			}
			if _, err = b.SettleModelTokenReservation(r.ID, 30, tokenPrice(30), earning); err != nil {
				t.Fatal(err)
			}
			if s.GetBalance("consumer") != 30 || s.GetBalance("provider") != 30 || s.GetWithdrawableBalance("referrer") != 1 {
				t.Fatal("retry balances")
			}
		})
	}
}
