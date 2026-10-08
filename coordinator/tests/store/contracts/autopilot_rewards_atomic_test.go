package store_test

import (
	"context"
	"errors"
	"math"
	"reflect"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/erasurefixture"
)

func TestAutopilotRewardsConcurrentCapAndDuplicate(t *testing.T) {
	autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
		machines := []earningsfloor.Enrollment{f.enroll(t, "first", "owner", 70), f.enroll(t, "second", "owner", 70)}
		f.fund(t, 11)
		run := func(cap int64) {
			t.Helper()
			var wg sync.WaitGroup
			for i := range 32 {
				wg.Add(1)
				go func() {
					defer wg.Done()
					enrollment := machines[i%2]
					if _, err := f.rewards.SettleAutopilotRewardDay(t.Context(), enrollment.MachineID, enrollment.NextDay); err != nil {
						t.Error(err)
					}
					if _, err := f.rewards.SetAutopilotRewardPoolCap(t.Context(), cap); err != nil {
						t.Error(err)
					}
				}()
			}
			wg.Wait()
		}
		run(11)
		var paid, pending int
		for _, enrollment := range machines {
			receipt := f.settle(t, enrollment.MachineID, enrollment.NextDay)
			if receipt.Status == earningsfloor.Paid && receipt.AmountMicroUSD == 11 {
				paid++
			} else if receipt.Status == earningsfloor.PoolExhausted && receipt.AmountMicroUSD == 0 {
				pending++
			}
		}
		pool, err := f.rewards.AutopilotRewardPool(t.Context())
		if err != nil || pool.SpentMicroUSD != 11 || paid != 1 || pending != 1 || len(f.backend.LedgerHistory("owner")) != 1 {
			t.Fatalf("concurrent cap/duplicates: pool=%+v paid=%d pending=%d, %v", pool, paid, pending, err)
		}
		f.fund(t, 22)
		run(22)
		pool, err = f.rewards.AutopilotRewardPool(t.Context())
		if err != nil || pool.SpentMicroUSD != 22 || len(f.backend.LedgerHistory("owner")) != 2 {
			t.Fatalf("refill/duplicates = %+v, %v", pool, err)
		}
		if balance, withdrawable := f.backend.GetBalanceWithWithdrawable("owner"); balance != 22 || withdrawable != 22 {
			t.Fatalf("same-account machines or retries double-credited: %d/%d", balance, withdrawable)
		}
	})
}

func TestAutopilotRewardsRejectedCreditsAreAtomic(t *testing.T) {
	for _, scenario := range []string{"balance_overflow", "earnings_summary_overflow", "negative_daily_inference"} {
		t.Run(scenario, func(t *testing.T) {
			autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
				enrollment := f.enroll(t, "session", "owner", 70)
				f.fund(t, math.MaxInt64)
				switch scenario {
				case "balance_overflow":
					if err := f.backend.CreditWithdrawable("owner", math.MaxInt64, store.LedgerAdminReward, "overflow-fixture"); err != nil {
						t.Fatal(err)
					}
				case "earnings_summary_overflow":
					f.earning(t, "session", "owner", math.MaxInt64-70, f.optIn.Add(-9*24*time.Hour))
				case "negative_daily_inference":
					f.earning(t, "session", "owner", -1, f.optIn.Add(time.Hour))
				}
				balance, withdrawable := f.backend.GetBalanceWithWithdrawable("owner")
				ledger := f.backend.LedgerHistory("owner")
				earnings, err := f.backend.GetAccountEarnings("owner", 100)
				if err != nil {
					t.Fatal(err)
				}
				if _, err := f.rewards.SettleAutopilotRewardDay(t.Context(), enrollment.MachineID, enrollment.NextDay); err == nil {
					t.Fatalf("accepted %s", scenario)
				}
				pool, err := f.rewards.AutopilotRewardPool(t.Context())
				if err != nil || pool.SpentMicroUSD != 0 || !readAutopilotRewardEnrollment(t, f, enrollment.MachineID).NextDay.Equal(enrollment.NextDay) {
					t.Fatalf("failed credit advanced pool or receipt cursor: %+v, %v", pool, err)
				}
				actualEarnings, err := f.backend.GetAccountEarnings("owner", 100)
				if err != nil || !reflect.DeepEqual(earnings, actualEarnings) || !reflect.DeepEqual(ledger, f.backend.LedgerHistory("owner")) {
					t.Fatalf("failed credit left ledger/earning side effects: %v", err)
				}
				if gotBalance, gotWithdrawable := f.backend.GetBalanceWithWithdrawable("owner"); gotBalance != balance || gotWithdrawable != withdrawable {
					t.Fatalf("failed credit changed wallet: %d/%d -> %d/%d", balance, withdrawable, gotBalance, gotWithdrawable)
				}
				if scenario == "balance_overflow" {
					if err := f.backend.Debit("owner", math.MaxInt64, store.LedgerWithdrawal, "repair-fixture"); err != nil {
						t.Fatal(err)
					}
					if retry := f.settle(t, enrollment.MachineID, enrollment.NextDay); retry.Status != earningsfloor.Paid || retry.AmountMicroUSD != 11 {
						t.Fatalf("rollback poisoned successful retry: %+v", retry)
					}
				}
			})
		})
	}
}

func TestAutopilotRewardsCancellationIsAtomic(t *testing.T) {
	autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
		enrollment := f.enroll(t, "session", "owner", 70)
		f.fund(t, 11)
		canceled, cancel := context.WithCancel(t.Context())
		cancel()
		if _, err := f.rewards.SetAutopilotRewardPoolCap(canceled, 1000); !errors.Is(err, context.Canceled) {
			t.Fatalf("canceled cap update = %v", err)
		}
		if _, err := f.rewards.ObserveAutopilotConsent(canceled, earningsfloor.Consent{SessionID: "session", AccountID: "owner", Supported: true, At: f.optIn.Add(time.Hour)}); !errors.Is(err, context.Canceled) {
			t.Fatalf("canceled consent update = %v", err)
		}
		if _, err := f.rewards.AutopilotRewardEnrollments(canceled, "", 100); !errors.Is(err, context.Canceled) {
			t.Fatalf("canceled enrollment scan = %v", err)
		}
		if _, err := f.rewards.RestoreAutopilotBaseline(canceled, earningsfloor.Baseline{MachineID: enrollment.MachineID, FirstOptInAt: f.optIn, SevenDayEarningsMicroUSD: 70, Evidence: "canceled audit"}); !errors.Is(err, context.Canceled) {
			t.Fatalf("canceled baseline restore = %v", err)
		}
		if _, err := f.rewards.SettleAutopilotRewardDay(canceled, enrollment.MachineID, enrollment.NextDay); !errors.Is(err, context.Canceled) {
			t.Fatalf("pre-canceled settlement = %v", err)
		}
		// The injected production clock deterministically cancels after method
		// entry, without a sleep, store mock, or test-only transaction callback.
		midCall, cancelMidCall := context.WithCancel(t.Context())
		defer cancelMidCall()
		f.nowHook = cancelMidCall
		_, err := f.rewards.SettleAutopilotRewardDay(midCall, enrollment.MachineID, enrollment.NextDay)
		f.nowHook = nil
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("in-flight canceled settlement = %v", err)
		}
		consentCall, cancelConsent := context.WithCancel(t.Context())
		defer cancelConsent()
		f.nowHook = cancelConsent
		_, err = f.rewards.ObserveAutopilotConsent(consentCall, earningsfloor.Consent{SessionID: "session", AccountID: "owner", Supported: true, At: f.optIn.Add(time.Hour)})
		f.nowHook = nil
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("in-flight canceled declaration = %v", err)
		}
		pool, err := f.rewards.AutopilotRewardPool(t.Context())
		if err != nil || pool.CapMicroUSD != 11 || pool.SpentMicroUSD != 0 || len(f.backend.LedgerHistory("owner")) != 0 || f.backend.GetBalance("owner") != 0 {
			t.Fatalf("cancellation left money mutations: %+v, %v", pool, err)
		}
		current := readAutopilotRewardEnrollment(t, f, enrollment.MachineID)
		if !current.OptedIn || !current.NextDay.Equal(enrollment.NextDay) || !current.ObservedAt.Equal(enrollment.ObservedAt) {
			t.Fatalf("cancellation changed enrollment: %+v", current)
		}
		if retry := f.settle(t, enrollment.MachineID, enrollment.NextDay); retry.Status != earningsfloor.Paid || retry.AmountMicroUSD != 11 {
			t.Fatalf("cancellation poisoned retry: %+v", retry)
		}
	})
}

func TestAutopilotRewardsErasureFencesCredit(t *testing.T) {
	for _, scrub := range []bool{false, true} {
		name := "pending_erasure"
		if scrub {
			name = "erased"
		}
		t.Run(name, func(t *testing.T) {
			autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
				account := erasurefixture.SeedAccount(t, f.backend)
				enrollment := f.enroll(t, account.ProviderID, account.AccountID, 70)
				f.fund(t, 1000)
				at := time.UnixMicro(f.clock.Load()).UTC()
				request := erasurefixture.PlanAndConfirm(t, f.backend, account, at, 0)
				if scrub {
					if _, err := f.backend.ScrubAccount(t.Context(), request.ID, at); err != nil {
						t.Fatal(err)
					}
				}
				balance, withdrawable := f.backend.GetBalanceWithWithdrawable(account.AccountID)
				ledger := f.backend.LedgerHistory(account.AccountID)
				if _, err := f.rewards.SettleAutopilotRewardDay(t.Context(), enrollment.MachineID, enrollment.NextDay); !errors.Is(err, store.ErrErasureConflict) {
					t.Fatalf("erasure did not fence settlement: %v", err)
				}
				if _, err := f.rewards.ObserveAutopilotConsent(t.Context(), earningsfloor.Consent{SessionID: account.ProviderID, AccountID: account.AccountID, Supported: true, OptedIn: true, At: f.optIn.Add(time.Hour)}); !errors.Is(err, store.ErrErasureConflict) {
					t.Fatalf("erasure did not fence consent: %v", err)
				}
				if _, err := f.rewards.RestoreAutopilotBaseline(t.Context(), earningsfloor.Baseline{MachineID: enrollment.MachineID, FirstOptInAt: f.optIn, SevenDayEarningsMicroUSD: 70, Evidence: "audit"}); !errors.Is(err, store.ErrErasureConflict) {
					t.Fatalf("erasure did not fence backfill: %v", err)
				}
				pool, err := f.rewards.AutopilotRewardPool(t.Context())
				if err != nil || pool.SpentMicroUSD != 0 || !reflect.DeepEqual(ledger, f.backend.LedgerHistory(account.AccountID)) {
					t.Fatalf("erased credit consumed allowance: %+v, %v", pool, err)
				}
				if gotBalance, gotWithdrawable := f.backend.GetBalanceWithWithdrawable(account.AccountID); gotBalance != balance || gotWithdrawable != withdrawable {
					t.Fatalf("erased wallet changed: %d/%d -> %d/%d", balance, withdrawable, gotBalance, gotWithdrawable)
				}
			})
		})
	}
}
