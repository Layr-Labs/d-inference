package store_test

import (
	"context"
	"errors"
	"reflect"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/erasurefixture"
)

func TestErasureOutboxRejectsStaleResults(t *testing.T) {
	for _, outcome := range []string{"progress", "done", "retry", "manual", "split"} {
		t.Run(outcome, func(t *testing.T) {
			for name, s := range storeBackends(t) {
				t.Run(name, func(t *testing.T) {
					ctx := context.Background()
					a := erasurefixture.SeedAccount(t, s)
					now := time.Now().UTC().Truncate(time.Microsecond)
					req := erasurefixture.PlanAndConfirm(t, s, a, now, 0)
					if _, err := s.ScrubAccount(ctx, req.ID, now); err != nil {
						t.Fatal(err)
					}
					older := claimCheckoutOutbox(t, s, now, now, time.Minute)
					later := now.Add(2 * time.Minute)
					newer := claimCheckoutOutbox(t, s, later, later, time.Minute)
					if newer.ID != older.ID || newer.LeaseGeneration != older.LeaseGeneration+1 || newer.JobGeneration != older.JobGeneration {
						t.Fatalf("reclaim must advance only lease generation: older=%+v newer=%+v", older, newer)
					}
					current := store.ErasureOutboxResult{
						LeaseGeneration: newer.LeaseGeneration, State: store.ErasureOutboxPending, ExternalID: newer.ExternalID,
						StripeJobID: "prj_current", JobGeneration: 1, JobStatus: "validating", JobStatusSince: &later,
						NextAt: later.Add(time.Minute),
					}
					// The stale callback arrives while the newer worker owns the row.
					stale := store.ErasureOutboxResult{
						LeaseGeneration: older.LeaseGeneration, State: store.ErasureOutboxPending, ExternalID: older.ExternalID,
						StripeJobID: "prj_stale", NextAt: now,
					}
					switch outcome {
					case "done":
						stale.State = store.ErasureOutboxDone
					case "retry":
						stale.Attempts, stale.LastError = 5, "stale failure"
					case "manual":
						stale.State, stale.LastError = store.ErasureOutboxManualAction, "stale terminal failure"
					case "split":
						stale.Split = &store.ErasureOutboxItem{ID: uniqueID("stale-split"), RequestID: req.ID, Target: store.ErasureTargetCheckoutSessions, ExternalID: "cs_missing"}
					}
					assertOutboxConflictUnchanged(t, s, a.AccountID, older.ID, stale)
					if err := s.SaveErasureOutboxResult(ctx, newer.ID, current); err != nil {
						t.Fatalf("current owner save: %v", err)
					}
					// A stale callback cannot overwrite progress after the lease ends,
					// and the successful claim itself is single-use.
					assertOutboxConflictUnchanged(t, s, a.AccountID, older.ID, stale)
					assertOutboxConflictUnchanged(t, s, a.AccountID, newer.ID, current)
				})
			}
		})
	}
}

func TestErasureOutboxRejectsExpiredUnclaimedLease(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			a := erasurefixture.SeedAccount(t, s)
			now := time.Now().UTC()
			req := erasurefixture.PlanAndConfirm(t, s, a, now, 0)
			if _, err := s.ScrubAccount(ctx, req.ID, now); err != nil {
				t.Fatal(err)
			}
			row := claimCheckoutOutbox(t, s, now, now.Add(-2*time.Minute), time.Minute)
			assertOutboxConflictUnchanged(t, s, a.AccountID, row.ID, store.ErasureOutboxResult{
				LeaseGeneration: row.LeaseGeneration, State: store.ErasureOutboxDone, NextAt: now,
			})
		})
	}
}

func TestErasureOutboxDueCutoffIsIndependentOfLeaseStart(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			a := erasurefixture.SeedAccount(t, s)
			cutoff := time.Now().UTC().Truncate(time.Microsecond)
			req := erasurefixture.PlanAndConfirm(t, s, a, cutoff, 0)
			if _, err := s.ScrubAccount(ctx, req.ID, cutoff); err != nil {
				t.Fatal(err)
			}
			row := claimCheckoutOutbox(t, s, cutoff, cutoff, time.Minute)
			next := cutoff.Add(time.Second)
			if err := s.SaveErasureOutboxResult(ctx, row.ID, store.ErasureOutboxResult{
				LeaseGeneration: row.LeaseGeneration, State: store.ErasureOutboxPending, ExternalID: row.ExternalID, NextAt: next,
			}); err != nil {
				t.Fatal(err)
			}
			// All other rows are still leased. This row is due relative to the
			// current clock, but was already handled in the pass being drained.
			rows, err := s.LeaseDueErasureOutbox(ctx, cutoff, next, time.Minute, 20)
			if err != nil || len(rows) != 0 {
				t.Fatalf("same pass reclaimed a rescheduled row: %+v, %v", rows, err)
			}
			reclaimed := claimCheckoutOutbox(t, s, next, next, time.Minute)
			if reclaimed.ID != row.ID || reclaimed.LeaseGeneration != row.LeaseGeneration+1 {
				t.Fatalf("next pass claim = %+v", reclaimed)
			}
		})
	}
}

func claimCheckoutOutbox(t *testing.T, s store.Store, dueBefore, now time.Time, lease time.Duration) store.ErasureOutboxWork {
	t.Helper()
	rows, err := s.LeaseDueErasureOutbox(context.Background(), dueBefore, now, lease, 20)
	if err != nil {
		t.Fatal(err)
	}
	for _, row := range rows {
		if row.Target == store.ErasureTargetCheckoutSessions {
			return row
		}
	}
	t.Fatalf("no checkout row among leased rows: %+v", rows)
	return store.ErasureOutboxWork{}
}

func assertOutboxConflictUnchanged(t *testing.T, s store.Store, accountID, id string, result store.ErasureOutboxResult) {
	t.Helper()
	ctx := context.Background()
	_, before, err := s.GetAccountErasure(ctx, accountID)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.SaveErasureOutboxResult(ctx, id, result); !errors.Is(err, store.ErrErasureConflict) {
		t.Fatalf("stale save = %v; want ErrErasureConflict", err)
	}
	_, after, err := s.GetAccountErasure(ctx, accountID)
	if err != nil || !reflect.DeepEqual(before, after) {
		t.Fatalf("rejected result changed outbox rows: before=%+v after=%+v error=%v", before, after, err)
	}
}
