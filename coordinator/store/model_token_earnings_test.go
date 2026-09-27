package store

import (
	"context"
	"fmt"
	"math"
	"os"
	"sync"
	"testing"
)

func TestModelTokenPromotionFractionalEarningsAtomicAndDurable(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			b, _ := promotionFixture(t, s, 100)
			quote := func(int64) (int64, int64, error) { return 1, 0, nil }
			earning := func(id string) *ModelTokenEarning {
				return &ModelTokenEarning{ProviderEarning: ProviderEarning{AccountID: "provider", JobID: id}, FractionalMicroUSD: 5_000_000}
			}
			for i := range 39 {
				if _, err := b.ReserveModelTokens(fmt.Sprint(i), "consumer", "not-registered/model", 1, quote); err != nil {
					t.Fatal(err)
				}
			}
			var wg sync.WaitGroup
			for i := range 39 {
				wg.Add(1)
				go func() {
					defer wg.Done()
					id := fmt.Sprint(i)
					for range 2 { // Replay must not accumulate the fraction again.
						if _, err := b.SettleModelTokenReservation(id, 1, quote, earning(id)); err != nil {
							t.Error(err)
						}
					}
				}()
			}
			wg.Wait()
			if got := s.GetWithdrawableBalance("provider"); got != 1 {
				t.Fatalf("39 requests paid %d", got)
			}
			if _, ok := s.(*PostgresStore); ok {
				fresh, err := NewPostgres(context.Background(), Config{DatabaseURL: os.Getenv("DATABASE_URL")})
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(fresh.Close)
				b = fresh // New pool: remainder must survive process-local state.
			}
			// A rejected settlement must not modify the persisted 0.95 remainder.
			if _, err := b.ReserveModelTokens("rejected", "consumer", "not-registered/model", 1, quote); err != nil {
				t.Fatal(err)
			}
			bad := earning("rejected")
			bad.FractionalMicroUSD = ModelTokenPayoutScale
			if _, err := b.SettleModelTokenReservation("rejected", 1, quote, bad); err == nil {
				t.Fatal("invalid fraction accepted")
			}
			if _, err := b.ReleaseModelTokenReservation("rejected"); err != nil {
				t.Fatal(err)
			}
			if _, err := b.ReserveModelTokens("last", "consumer", "not-registered/model", 1, quote); err != nil {
				t.Fatal(err)
			}
			// Force the provider credit to fail after PostgreSQL updates carry.
			// The transaction must roll the remainder and grant counters back.
			if err := s.Credit("provider", math.MaxInt64-1, LedgerAdminCredit, "overflow-fixture"); err != nil {
				t.Fatal(err)
			}
			if _, err := b.SettleModelTokenReservation("last", 1, quote, earning("last")); err == nil {
				t.Fatal("overflowing provider credit accepted")
			}
			if err := s.Debit("provider", math.MaxInt64-1, LedgerCharge, "restore-fixture"); err != nil {
				t.Fatal(err)
			}
			result, err := b.SettleModelTokenReservation("last", 1, quote, earning("last"))
			if err != nil || result.Reservation.ProviderPayoutMicroUSD != 1 {
				t.Fatalf("carry payout: %+v %v", result, err)
			}
			if got := s.GetWithdrawableBalance("provider"); got != 2 {
				t.Fatalf("40 requests paid %d", got)
			}
			grants, _ := b.ListModelTokenGrants("consumer")
			if grants[0].UsedTokens != 40 || grants[0].ReservedTokens != 0 {
				t.Fatal(grants)
			}
		})
	}
}
