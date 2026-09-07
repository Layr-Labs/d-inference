package store

import (
	"context"
	"errors"
	"math"
	"sync"
	"sync/atomic"
	"testing"
)

func seedConsumerReferral(t *testing.T, s Store, consumer, referrer string) {
	t.Helper()
	if err := s.CreateReferrer(referrer, referrer); err != nil {
		t.Fatal(err)
	}
	if err := s.RecordReferral(referrer, consumer); err != nil {
		t.Fatal(err)
	}
}

func TestConsumerSettlementAmounts(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			for _, tc := range []struct {
				name                               string
				balance, reserved, cost, collected int64
				uncollected                        bool
			}{
				{"direct", 1000, 0, 400, 400, false},
				{"refund", 1000, 600, 400, 400, false},
				{"exact", 1000, 400, 400, 400, false},
				{"overage", 1000, 300, 500, 500, false},
				{"overage_cap", 1000, 300, 900, 600, false},
				{"unfunded_overage", 300, 300, 500, 300, false},
				{"unfunded_direct", 300, 0, 500, 0, true},
				{"free", 1000, 600, 0, 0, false},
				{"round_down", 1000, 0, 39, 39, false},
				{"sub_micro_reward", 1000, 0, 19, 19, false},
			} {
				t.Run(tc.name, func(t *testing.T) {
					consumer, referrer := uniqueID("consumer"), uniqueID("referrer")
					seedConsumerReferral(t, s, consumer, referrer)
					if err := s.Credit(consumer, tc.balance, LedgerInviteCredit, "grant"); err != nil {
						t.Fatal(err)
					}
					if tc.reserved > 0 {
						if err := s.Debit(consumer, tc.reserved, LedgerCharge, "reserve:"+consumer); err != nil {
							t.Fatal(err)
						}
					}
					in := ConsumerChargeSettlement{AccountID: consumer, JobID: uniqueID("job"), ReservedMicroUSD: tc.reserved, CostMicroUSD: tc.cost, ReferralEnabled: true}
					got, err := s.FinalizeConsumerCharge(in)
					if err != nil {
						t.Fatal(err)
					}
					if !got.Applied || got.CollectedMicroUSD != tc.collected || got.ReferralRewardMicroUSD != tc.collected/20 || got.Uncollected != tc.uncollected {
						t.Fatalf("result=%+v", got)
					}
					if bal := s.GetBalance(consumer); bal != tc.balance-tc.collected {
						t.Fatalf("consumer balance=%d", bal)
					}
					if bal := s.GetWithdrawableBalance(referrer); bal != tc.collected/20 {
						t.Fatalf("reward=%d", bal)
					}
					stats, err := s.GetReferralStats(referrer)
					if err != nil {
						t.Fatal(err)
					}
					if stats.TotalReferredSpendMicroUSD != tc.collected || stats.TotalRewardsMicroUSD != tc.collected/20 {
						t.Fatalf("stats=%+v", stats)
					}
					before := len(s.LedgerHistory(consumer))
					replay, err := s.FinalizeConsumerCharge(in)
					if err != nil || replay.Applied {
						t.Fatalf("replay=%+v err=%v", replay, err)
					}
					if len(s.LedgerHistory(consumer)) != before || s.GetBalance(consumer) != tc.balance-tc.collected {
						t.Fatal("replay mutated consumer")
					}
					in.CostMicroUSD++
					if _, err := s.FinalizeConsumerCharge(in); err == nil {
						t.Fatal("changed replay accepted")
					}
				})
			}
		})
	}
}

func TestConsumerSettlementConcurrentDuplicate(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			consumer, referrer := uniqueID("consumer"), uniqueID("referrer")
			seedConsumerReferral(t, s, consumer, referrer)
			if err := s.Credit(consumer, 1000, LedgerDeposit, "seed"); err != nil {
				t.Fatal(err)
			}
			in := ConsumerChargeSettlement{AccountID: consumer, JobID: uniqueID("job"), CostMicroUSD: 400, ReferralEnabled: true}
			var applied atomic.Int32
			var wg sync.WaitGroup
			for range 24 {
				wg.Add(1)
				go func() {
					defer wg.Done()
					r, err := s.FinalizeConsumerCharge(in)
					if err != nil {
						t.Error(err)
					}
					if r.Applied {
						applied.Add(1)
					}
				}()
			}
			wg.Wait()
			if applied.Load() != 1 || s.GetBalance(consumer) != 600 || s.GetBalance(referrer) != 20 || len(s.LedgerHistory(referrer)) != 1 {
				t.Fatalf("applied=%d consumer=%d referrer=%d", applied.Load(), s.GetBalance(consumer), s.GetBalance(referrer))
			}
		})
	}
}

func TestConsumerSettlementRewardFailureRollsBackAndRetries(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			consumer, referrer := uniqueID("consumer"), uniqueID("referrer")
			seedConsumerReferral(t, s, consumer, referrer)
			if err := s.Credit(consumer, 1000, LedgerDeposit, "seed"); err != nil {
				t.Fatal(err)
			}
			if err := s.Credit(referrer, math.MaxInt64, LedgerDeposit, "overflow"); err != nil {
				t.Fatal(err)
			}
			in := ConsumerChargeSettlement{AccountID: consumer, JobID: uniqueID("job"), CostMicroUSD: 400, ReferralEnabled: true}
			if _, err := s.FinalizeConsumerCharge(in); err == nil {
				t.Fatal("expected reward overflow to fail transaction")
			}
			if s.GetBalance(consumer) != 1000 || len(s.LedgerHistory(consumer)) != 1 || len(s.LedgerHistory(referrer)) != 1 {
				t.Fatal("failed reward partially settled")
			}
			if err := s.Debit(referrer, math.MaxInt64, LedgerCharge, "clear"); err != nil {
				t.Fatal(err)
			}
			got, err := s.FinalizeConsumerCharge(in)
			if err != nil || !got.Applied || got.ReferralRewardMicroUSD != 20 {
				t.Fatalf("retry=%+v err=%v", got, err)
			}
		})
	}
}

func TestConsumerSettlementAttributionIsNotRetroactive(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			consumer, referrer := uniqueID("consumer"), uniqueID("referrer")
			if err := s.Credit(consumer, 1000, LedgerDeposit, "seed"); err != nil {
				t.Fatal(err)
			}
			in := ConsumerChargeSettlement{AccountID: consumer, JobID: uniqueID("job"), CostMicroUSD: 400, ReferralEnabled: true}
			if _, err := s.FinalizeConsumerCharge(in); err != nil {
				t.Fatal(err)
			}
			seedConsumerReferral(t, s, consumer, referrer)
			if _, err := s.FinalizeConsumerCharge(in); err != nil {
				t.Fatal(err)
			}
			if s.GetBalance(referrer) != 0 {
				t.Fatal("replay paid newly-applied referrer")
			}
			stats, err := s.GetReferralStats(referrer)
			if err != nil || stats.TotalReferredSpendMicroUSD != 0 {
				t.Fatalf("stats=%+v err=%v", stats, err)
			}
			in.JobID = uniqueID("job")
			in.ReferralEnabled = false
			if _, err := s.FinalizeConsumerCharge(in); err != nil {
				t.Fatal(err)
			}
			if s.GetBalance(referrer) != 0 {
				t.Fatal("disabled referral paid")
			}
		})
	}
}

func TestConsumerSettlementOverflowSafeRate(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			consumer, referrer := uniqueID("consumer"), uniqueID("referrer")
			seedConsumerReferral(t, s, consumer, referrer)
			if err := s.Credit(consumer, math.MaxInt64, LedgerDeposit, "seed"); err != nil {
				t.Fatal(err)
			}
			got, err := s.FinalizeConsumerCharge(ConsumerChargeSettlement{AccountID: consumer, JobID: uniqueID("job"), CostMicroUSD: math.MaxInt64, ReferralEnabled: true})
			if err != nil || got.ReferralRewardMicroUSD != math.MaxInt64/20 {
				t.Fatalf("result=%+v err=%v", got, err)
			}
		})
	}
}

func TestReferralAttributionAtomicAndImmutable(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			consumer, a, b := uniqueID("consumer"), uniqueID("ref-a"), uniqueID("ref-b")
			for _, ref := range []string{a, b} {
				if err := s.CreateReferrer(ref, ref); err != nil {
					t.Fatal(err)
				}
			}
			if err := s.RecordReferral(a, a); !errors.Is(err, ErrReferralConflict) {
				t.Fatalf("self referral=%v", err)
			}
			var wg sync.WaitGroup
			var success atomic.Int32
			for _, code := range []string{a, b} {
				wg.Add(1)
				go func() {
					defer wg.Done()
					err := s.RecordReferral(code, consumer)
					if err == nil {
						success.Add(1)
					} else if !errors.Is(err, ErrReferralConflict) {
						t.Error(err)
					}
				}()
			}
			wg.Wait()
			if success.Load() != 1 {
				t.Fatalf("successful attributions=%d", success.Load())
			}
			code, err := s.GetReferrerForAccount(consumer)
			if err != nil {
				t.Fatal(err)
			}
			if err := s.RecordReferral(code, consumer); err != nil {
				t.Fatalf("same code replay=%v", err)
			}
			stats, err := s.GetReferralStats(code)
			if err != nil || stats.TotalReferred != 1 {
				t.Fatalf("stats=%+v err=%v", stats, err)
			}
		})
	}
}

func TestPostgresConsumerSettlementSurvivesNewStore(t *testing.T) {
	s := testPostgresStore(t)
	consumer, referrer := uniqueID("consumer"), uniqueID("referrer")
	seedConsumerReferral(t, s, consumer, referrer)
	if err := s.Credit(consumer, 1000, LedgerDeposit, "seed"); err != nil {
		t.Fatal(err)
	}
	in := ConsumerChargeSettlement{AccountID: consumer, JobID: uniqueID("job"), CostMicroUSD: 400, ReferralEnabled: true}
	if _, err := s.FinalizeConsumerCharge(in); err != nil {
		t.Fatal(err)
	}
	// A separately-created store/pool has no in-process finalization state.
	other, err := NewPostgres(context.Background(), Config{DatabaseURL: s.pool.Config().ConnString()})
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close()
	got, err := other.FinalizeConsumerCharge(in)
	if err != nil || got.Applied || got.ReferralRewardMicroUSD != 20 {
		t.Fatalf("replay=%+v err=%v", got, err)
	}
	if other.GetBalance(consumer) != 600 || other.GetBalance(referrer) != 20 {
		t.Fatal("reconnected replay mutated balances")
	}
}

func TestConsumerSettlementReciprocalReferralsDoNotDeadlock(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			a, b := uniqueID("account-a"), uniqueID("account-b")
			seedConsumerReferral(t, s, a, b)
			seedConsumerReferral(t, s, b, a)
			for _, account := range []string{a, b} {
				if err := s.Credit(account, 1000, LedgerDeposit, "seed"); err != nil {
					t.Fatal(err)
				}
			}
			start := make(chan struct{})
			var wg sync.WaitGroup
			for _, account := range []string{a, b} {
				in := ConsumerChargeSettlement{AccountID: account, JobID: uniqueID("job"), CostMicroUSD: 400, ReferralEnabled: true}
				wg.Add(1)
				go func() {
					defer wg.Done()
					<-start
					if _, err := s.FinalizeConsumerCharge(in); err != nil {
						t.Error(err)
					}
				}()
			}
			close(start)
			wg.Wait()
			for _, account := range []string{a, b} {
				if got := s.GetBalance(account); got != 620 {
					t.Fatalf("balance = %d, want 620", got)
				}
			}
		})
	}
}
