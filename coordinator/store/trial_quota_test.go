package store

import (
	"context"
	"fmt"
	"math/rand"
	"sync"
	"testing"
)

func TestTrialQuotaBoundariesAndIdentity(t *testing.T) {
	trialBackends(t, func(t *testing.T, _ Store, tr TrialStore) {
		ctx := context.Background()
		r := trialRequest("quota", "account", 900)
		reserveAndDispatch(t, tr, r)
		if err := tr.SettleTrial(ctx, r.ID, trialSettlement(r, 850, 50)); err != nil {
			t.Fatal(err)
		}
		_, err := tr.ReserveTrial(ctx, trialRequest("too-large", "account", 101))
		requireTrialError(t, err, ErrTrialRequestTooLarge)
		next := trialRequest("final", "account", 100)
		reserveAndDispatch(t, tr, next)
		_, err = tr.ReserveTrial(ctx, trialRequest("busy", "account", 1))
		requireTrialError(t, err, ErrTrialBusy)
		if err := tr.SettleTrial(ctx, next.ID, trialSettlement(next, 60, 40)); err != nil {
			t.Fatal(err)
		}
		_, err = tr.ReserveTrial(ctx, trialRequest("exhausted", "account", 1))
		requireTrialError(t, err, ErrTrialExhausted)
		assertAllowance(t, tr, r, 1000, 0)
		if _, err = tr.ReserveTrial(ctx, trialRequest("separate", "other-account", 1000)); err != nil {
			t.Fatal(err)
		}
		if _, err = tr.ReserveTrial(ctx, r); err != nil {
			t.Fatal("repeat reserve", err)
		}
		changed := r
		changed.AccountID = "other"
		_, err = tr.ReserveTrial(ctx, changed)
		requireTrialError(t, err, ErrTrialConflict)
		changed = r
		changed.PricingJSON = []byte(`{"input":999}`)
		_, err = tr.ReserveTrial(ctx, changed)
		requireTrialError(t, err, ErrTrialConflict)
		changed = trialRequest("changed-limit", "account", 1)
		changed.LimitTokens = 2000
		_, err = tr.ReserveTrial(ctx, changed)
		requireTrialError(t, err, ErrTrialConflict)
	})
}

func TestTrialConcurrentFirstReservation(t *testing.T) {
	trialBackends(t, func(t *testing.T, _ Store, tr TrialStore) {
		ctx := context.Background()
		start := make(chan struct{})
		errs := make(chan error, 24)
		var wg sync.WaitGroup
		for i := 0; i < 24; i++ {
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				<-start
				_, err := tr.ReserveTrial(ctx, trialRequest(fmt.Sprint("race-", i), "account", 700))
				errs <- err
			}(i)
		}
		close(start)
		wg.Wait()
		close(errs)
		success := 0
		for err := range errs {
			if err == nil {
				success++
			} else {
				requireTrialError(t, err, ErrTrialBusy)
			}
		}
		if success != 1 {
			t.Fatalf("success=%d", success)
		}
		assertAllowance(t, tr, trialRequest("", "account", 0), 0, 700)
	})
}

func TestTrialUnknownCompletionRetainsHold(t *testing.T) {
	trialBackends(t, func(t *testing.T, _ Store, tr TrialStore) {
		ctx := context.Background()
		r := trialRequest("unresolved", "account", 1000)
		reserveAndDispatch(t, tr, r)
		if err := tr.ReleaseTrial(ctx, r.ID, false); err != nil {
			t.Fatal(err)
		}
		assertAllowance(t, tr, r, 0, 1000)
		got, err := tr.GetTrialReservation(ctx, r.ID)
		if err != nil || got.State != TrialUnresolved {
			t.Fatalf("reservation=%+v err=%v", got, err)
		}
		_, err = tr.ReserveTrial(ctx, trialRequest("blocked", "account", 1))
		requireTrialError(t, err, ErrTrialUnavailable)
		if err = tr.SettleTrial(ctx, r.ID, trialSettlement(r, 20, 30)); err != nil {
			t.Fatal(err)
		}
		assertAllowance(t, tr, r, 50, 0)
	})
}

func TestTrialRandomizedSchedules(t *testing.T) {
	trialBackends(t, func(t *testing.T, _ Store, tr TrialStore) {
		rng := rand.New(rand.NewSource(71))
		ctx := context.Background()
		used := int64(0)
		for i := 0; i < 60; i++ {
			r := trialRequest(fmt.Sprint("random-", i), "account", 20)
			_, err := tr.ReserveTrial(ctx, r)
			if err != nil {
				if used > 980 {
					break
				}
				t.Fatal(err)
			}
			if rng.Intn(3) == 0 {
				if err = tr.ReleaseTrial(ctx, r.ID, false); err != nil {
					t.Fatal(err)
				}
			} else {
				if err = tr.MarkTrialDispatched(ctx, r.ID); err != nil {
					t.Fatal(err)
				}
				n := rng.Intn(20)
				x := trialSettlement(r, n, 0)
				if err = tr.SettleTrial(ctx, r.ID, x); err != nil {
					t.Fatal(err)
				}
				used += int64(n)
			}
			assertAllowance(t, tr, r, used, 0)
		}
	})
}

func TestTrialReleaseBeforeDispatchAndDuplicateIdentity(t *testing.T) {
	trialBackends(t, func(t *testing.T, s Store, tr TrialStore) {
		ctx := context.Background()
		r := trialRequest("release", "account", 1000)
		got, err := tr.ReserveTrial(ctx, r)
		if err != nil {
			t.Fatal(err)
		}
		got.PricingJSON[0] = 'x'
		again, err := tr.GetTrialReservation(ctx, r.ID)
		if err != nil || string(again.PricingJSON) != string(r.PricingJSON) {
			t.Fatal("reservation escaped copy")
		}
		requireTrialError(t, tr.SettleTrial(ctx, r.ID, trialSettlement(r, 1, 1)), ErrTrialConflict)
		for i := 0; i < 2; i++ {
			if err = tr.ReleaseTrial(ctx, r.ID, false); err != nil {
				t.Fatal(err)
			}
		}
		assertAllowance(t, tr, r, 0, 0)
		requireTrialError(t, tr.MarkTrialDispatched(ctx, r.ID), ErrTrialConflict)
		requireTrialError(t, tr.SettleTrial(ctx, r.ID, trialSettlement(r, 1, 1)), ErrTrialConflict)
		if s.GetBalance("provider-account") != 0 {
			t.Fatal("released work paid")
		}
		if _, err = tr.ReserveTrial(ctx, r); err != nil {
			t.Fatal(err)
		}
		assertAllowance(t, tr, r, 0, 0)
		ctx, cancel := context.WithCancel(ctx)
		cancel()
		_, err = tr.ReserveTrial(ctx, trialRequest("cancelled", "account", 1))
		requireTrialError(t, err, context.Canceled)
	})
}
