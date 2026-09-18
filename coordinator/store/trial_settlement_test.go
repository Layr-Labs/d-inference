package store

import (
	"context"
	"errors"
	"math"
	"testing"
)

func TestTrialSettlementAtomicAndIdempotent(t *testing.T) {
	trialBackends(t, func(t *testing.T, s Store, tr TrialStore) {
		ctx := context.Background()
		r := trialRequest("settle", "consumer", 1000)
		if err := s.Credit("consumer", 777, LedgerDeposit, "deposit"); err != nil {
			t.Fatal(err)
		}
		reserveAndDispatch(t, tr, r)
		settlement := trialSettlement(r, 200, 100)
		for i := 0; i < 3; i++ {
			if err := tr.SettleTrial(ctx, r.ID, settlement); err != nil {
				t.Fatal(err)
			}
		}
		assertAllowance(t, tr, r, 300, 0)
		if s.GetBalance("consumer") != 777 || s.GetWithdrawableBalance("consumer") != 0 {
			t.Fatal("consumer balance changed")
		}
		if s.GetBalance("provider-account") != 80 || s.GetWithdrawableBalance("provider-account") != 80 {
			t.Fatal("provider not credited exactly once")
		}
		rows, err := s.GetAccountEarnings("provider-account", 10)
		if err != nil || len(rows) != 1 {
			t.Fatalf("earnings=%v err=%v", rows, err)
		}
		summary, err := s.GetAccountEarningsSummary("provider-account")
		if err != nil || summary.TotalMicroUSD != 80 {
			t.Fatalf("summary=%+v err=%v", summary, err)
		}
		usage := s.UsageByConsumer("consumer")
		if len(usage) != 1 || usage[0].CostMicroUSD != 0 || usage[0].PromptTokens != 200 {
			t.Fatalf("usage=%+v", usage)
		}
		if err := tr.ReleaseTrial(ctx, r.ID, true); err != nil {
			t.Fatal(err)
		}
		assertAllowance(t, tr, r, 300, 0)
		// Existing withdrawal path can consume the sponsored earnings.
		if err := s.DebitWithdrawable("provider-account", 80, LedgerWithdrawal, "withdraw"); err != nil {
			t.Fatal(err)
		}
		if s.GetBalance("provider-account") != 0 || s.GetWithdrawableBalance("provider-account") != 0 {
			t.Fatal("trial earning not withdrawable")
		}
	})
}

func TestTrialInvalidUsageCannotCredit(t *testing.T) {
	trialBackends(t, func(t *testing.T, s Store, tr TrialStore) {
		cases := map[string]func(*TrialSettlement){
			"negative":         func(x *TrialSettlement) { x.Usage.PromptTokens = -1 },
			"over-bound":       func(x *TrialSettlement) { x.Usage.CompletionTokens = 1001 },
			"overflow":         func(x *TrialSettlement) { x.Usage.PromptTokens = math.MaxInt; x.Usage.CompletionTokens = math.MaxInt },
			"charged":          func(x *TrialSettlement) { x.Usage.CostMicroUSD = 1 },
			"wrong-account":    func(x *TrialSettlement) { x.Usage.ConsumerKey = "wrong" },
			"wrong-model":      func(x *TrialSettlement) { x.Usage.Model = "wrong" },
			"missing-payout":   func(x *TrialSettlement) { x.Earning = nil },
			"negative-subsidy": func(x *TrialSettlement) { x.SubsidyMicroUSD = -1 },
			"excess-credit":    func(x *TrialSettlement) { x.Earning.AmountMicroUSD = 101 },
			"wrong-job":        func(x *TrialSettlement) { x.Earning.JobID = "wrong" },
			"key":              func(x *TrialSettlement) { x.Usage.KeyID = "key" },
		}
		for name, mutate := range cases {
			t.Run(name, func(t *testing.T) {
				r := trialRequest(name, name, 100)
				reserveAndDispatch(t, tr, r)
				x := trialSettlement(r, 20, 10)
				mutate(&x)
				requireTrialError(t, tr.SettleTrial(context.Background(), r.ID, x), ErrTrialInvalidUsage)
				assertAllowance(t, tr, r, 0, 100)
				if s.GetBalance("provider-account") != 0 {
					t.Fatal("invalid usage paid")
				}
				requireTrialError(t, tr.ReleaseTrial(context.Background(), r.ID, true), ErrTrialConflict)
				assertAllowance(t, tr, r, 0, 100)
			})
		}
	})
}

func TestTrialReleaseSettlementRace(t *testing.T) {
	trialBackends(t, func(t *testing.T, s Store, tr TrialStore) {
		r := trialRequest("race-final", "account", 100)
		reserveAndDispatch(t, tr, r)
		ctx := context.Background()
		start := make(chan struct{})
		errs := make(chan error, 2)
		go func() { <-start; errs <- tr.ReleaseTrial(ctx, r.ID, true) }()
		go func() { <-start; errs <- tr.SettleTrial(ctx, r.ID, trialSettlement(r, 20, 10)) }()
		close(start)
		for i := 0; i < 2; i++ {
			err := <-errs
			if err != nil && !errors.Is(err, ErrTrialConflict) {
				t.Fatal(err)
			}
		}
		got, err := tr.GetTrialReservation(ctx, r.ID)
		if err != nil {
			t.Fatal(err)
		}
		if got.State == TrialSettled {
			assertAllowance(t, tr, r, 30, 0)
			if s.GetBalance("provider-account") != 80 {
				t.Fatal("missing credit")
			}
		} else if got.State == TrialReleased {
			assertAllowance(t, tr, r, 0, 0)
			if s.GetBalance("provider-account") != 0 {
				t.Fatal("released request paid")
			}
		} else {
			t.Fatalf("state=%s", got.State)
		}
	})
}

func TestTrialConflictingPaidEarningRollsBack(t *testing.T) {
	trialBackends(t, func(t *testing.T, s Store, tr TrialStore) {
		r := trialRequest("collision", "account", 100)
		reserveAndDispatch(t, tr, r)
		settlement := trialSettlement(r, 10, 10)
		if err := s.CreditProviderAccount(settlement.Earning); err != nil {
			t.Fatal(err)
		}
		requireTrialError(t, tr.SettleTrial(context.Background(), r.ID, settlement), ErrTrialConflict)
		assertAllowance(t, tr, r, 0, 100)
		if s.GetBalance("provider-account") != 80 || len(s.UsageByConsumer("account")) != 0 {
			t.Fatal("conflict committed financial effects")
		}
	})
}

func TestTrialZeroUsageAndNoPayoutAccount(t *testing.T) {
	trialBackends(t, func(t *testing.T, s Store, tr TrialStore) {
		r := trialRequest("zero", "account", 100)
		reserveAndDispatch(t, tr, r)
		x := trialSettlement(r, 0, 0)
		x.Earning = nil
		x.SubsidyMicroUSD = 0
		if err := tr.SettleTrial(context.Background(), r.ID, x); err != nil {
			t.Fatal(err)
		}
		assertAllowance(t, tr, r, 0, 0)
		if s.GetBalance("provider-account") != 0 || len(s.UsageByConsumer("account")) != 1 {
			t.Fatal("zero usage settlement incorrect")
		}
	})
}

func TestTrialConcurrentDuplicateFinalization(t *testing.T) {
	trialBackends(t, func(t *testing.T, s Store, tr TrialStore) {
		r := trialRequest("duplicate-terminal", "account", 100)
		reserveAndDispatch(t, tr, r)
		start := make(chan struct{})
		errs := make(chan error, 16)
		for i := 0; i < 16; i++ {
			go func() { <-start; errs <- tr.SettleTrial(context.Background(), r.ID, trialSettlement(r, 20, 10)) }()
		}
		close(start)
		for i := 0; i < 16; i++ {
			if err := <-errs; err != nil {
				t.Fatal(err)
			}
		}
		assertAllowance(t, tr, r, 30, 0)
		if s.GetBalance("provider-account") != 80 || s.GetWithdrawableBalance("provider-account") != 80 || len(s.UsageByConsumer("account")) != 1 {
			t.Fatal("duplicate completion has repeated effects")
		}
	})
}

func TestTrialProviderBalanceOverflowRollsBack(t *testing.T) {
	trialBackends(t, func(t *testing.T, s Store, tr TrialStore) {
		r := trialRequest("balance-overflow", "account", 100)
		reserveAndDispatch(t, tr, r)
		if err := s.Credit("provider-account", math.MaxInt64, LedgerDeposit, "seed"); err != nil {
			t.Fatal(err)
		}
		requireTrialError(t, tr.SettleTrial(context.Background(), r.ID, trialSettlement(r, 20, 10)), ErrTrialUnavailable)
		assertAllowance(t, tr, r, 0, 100)
		if s.GetBalance("provider-account") != math.MaxInt64 || s.GetWithdrawableBalance("provider-account") != 0 || len(s.UsageByConsumer("account")) != 0 {
			t.Fatal("overflow committed effects")
		}
	})
}
