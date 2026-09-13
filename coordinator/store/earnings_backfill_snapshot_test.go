package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

func commitOldServingCredit(t *testing.T, s *PostgresStore) {
	t.Helper()
	tx, err := s.pool.Begin(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(context.Background())
	executeOldServingCredit(t, tx)
	if err := tx.Commit(context.Background()); err != nil {
		t.Fatal(err)
	}
}

func TestEarningsSummaryBackfillWriterCommitAfterAttemptMarker(t *testing.T) {
	s := seededLegacyEarningsStore(t)
	ctx := context.Background()
	marker := func(ctx context.Context) (bool, error) {
		claimed, err := s.claimEarningsSummaryAttempt(ctx)
		if err == nil && claimed {
			commitOldServingCredit(t, s)
		}
		return claimed, err
	}
	if err := prepareEarningsSummaryBackfill(ctx, s.pool, marker); err != nil {
		t.Fatal(err)
	}
	if _, err := s.applyEarningsSummaryMigration(ctx); err != nil {
		t.Fatal(err)
	}
	assertBackfilledWork(t, s)
}

func TestEarningsSummaryBackfillWriterCommitImmediatelyBeforeMarker(t *testing.T) {
	s := seededLegacyEarningsStore(t)
	ctx := context.Background()
	marker := func(ctx context.Context) (bool, error) {
		// The callback is invoked only after the planning snapshot is pinned.
		commitOldServingCredit(t, s)
		return s.claimEarningsSummaryAttempt(ctx)
	}
	if err := prepareEarningsSummaryBackfill(ctx, s.pool, marker); err != nil {
		t.Fatal(err)
	}
	if _, err := s.applyEarningsSummaryMigration(ctx); err != nil {
		t.Fatal(err)
	}
	assertBackfilledWork(t, s)
}

func assertNoAppliedPlan(t *testing.T, s *PostgresStore, wantAttempt bool) {
	t.Helper()
	ctx := context.Background()
	var ready, attempted, done bool
	err := s.pool.QueryRow(ctx, `SELECT
  EXISTS(SELECT 1 FROM schema_migrations WHERE id=$1),
  EXISTS(SELECT 1 FROM schema_migrations WHERE id=$2),
  EXISTS(SELECT 1 FROM schema_migrations WHERE id=$3)`, earningsSummaryPlanID, earningsSummaryPlanAttemptID, earningsSummaryMigrationID).Scan(&ready, &attempted, &done)
	if err != nil || ready || done || attempted != wantAttempt {
		t.Fatalf("markers: ready=%v attempted=%v done=%v err=%v", ready, attempted, done, err)
	}
	var n int
	if err := s.pool.QueryRow(ctx, `SELECT count(*) FROM earnings_summary_backfill_pending`).Scan(&n); err != nil || n != 0 {
		t.Fatalf("plan applied despite marker error: %d %v", n, err)
	}
}

func TestEarningsSummaryMarkerFailureNeverAppliesPinnedPlan(t *testing.T) {
	for _, committed := range []bool{false, true} {
		t.Run(map[bool]string{false: "before_marker", true: "uncertain_after_commit"}[committed], func(t *testing.T) {
			s := seededLegacyEarningsStore(t)
			marker := func(ctx context.Context) (bool, error) {
				if committed {
					if _, err := s.claimEarningsSummaryAttempt(ctx); err != nil {
						t.Fatal(err)
					}
				}
				return false, errors.New("marker acknowledgement unavailable")
			}
			if err := prepareEarningsSummaryBackfill(context.Background(), s.pool, marker); err == nil {
				t.Fatal("ignored marker failure")
			}
			assertNoAppliedPlan(t, s, committed)
			if committed {
				if _, err := s.applyEarningsSummaryMigration(context.Background()); err == nil {
					t.Fatal("uncertain marker was silently replanned")
				}
			}
		})
	}
}

func TestEarningsSummaryCancellationAfterMarkerPreservesIncompleteFence(t *testing.T) {
	s := seededLegacyEarningsStore(t)
	ctx, cancel := context.WithCancel(context.Background())
	marker := func(ctx context.Context) (bool, error) {
		claimed, err := s.claimEarningsSummaryAttempt(ctx)
		cancel()
		return claimed, err
	}
	if err := prepareEarningsSummaryBackfill(ctx, s.pool, marker); err == nil {
		t.Fatal("canceled plan completed")
	}
	assertNoAppliedPlan(t, s, true)
	// A canceled marker connection also exits promptly without acquiring a pool slot.
	before := s.pool.Stat().AcquiredConns()
	canceled, stop := context.WithCancel(context.Background())
	stop()
	began := time.Now()
	if _, err := s.claimEarningsSummaryAttempt(canceled); err == nil {
		t.Fatal("canceled marker writer succeeded")
	}
	if time.Since(began) > time.Second || s.pool.Stat().AcquiredConns() != before {
		t.Fatal("marker cancellation retained a pool lease or blocked")
	}
}
