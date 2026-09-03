package store

import (
	"context"
	"fmt"
	"testing"
	"time"
)

// seedDueVerificationJobs inserts n rows that are due at now.
func seedDueVerificationJobs(tb testing.TB, s verificationJobStore, prefix string, n int, now time.Time) {
	tb.Helper()
	for i := range n {
		if _, err := s.UpsertVerificationJob(context.Background(), VerificationJob{
			SEPubKey:      fmt.Sprintf("%s-%04d", prefix, i),
			Serial:        fmt.Sprintf("serial-%s-%04d", prefix, i),
			Kind:          VerificationTaskSecurityInfo,
			State:         VerificationStatePending,
			Priority:      VerificationPriorityRefresh,
			NextAttemptAt: now.Add(-time.Minute),
			UpdatedAt:     now,
		}); err != nil {
			tb.Fatalf("seed %s-%d: %v", prefix, i, err)
		}
	}
}

// TestListDueVerificationJobsPageDoesNotPreallocateTheLimit: the scheduler
// asks for its whole queue capacity (4,096) on every poll while only a few
// rows are usually due; the returned page must be sized for the rows, not the
// limit (the 4,096-row pre-allocation per poll was 16 % of all bytes the
// coordinator allocated).
func TestListDueVerificationJobsPageDoesNotPreallocateTheLimit(t *testing.T) {
	now := time.Date(2026, 9, 3, 12, 0, 0, 0, time.UTC)
	for name, st := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			if pg, ok := st.(*PostgresStore); ok {
				if _, err := pg.pool.Exec(context.Background(), "TRUNCATE provider_verification_jobs"); err != nil {
					t.Fatalf("truncate: %v", err)
				}
			}
			seedDueVerificationJobs(t, st, uniqueID("page"), 10, now)
			paged, ok := st.(interface {
				ListDueVerificationJobsPage(context.Context, time.Time, int, int) ([]VerificationJob, error)
			})
			if !ok {
				t.Fatalf("%T does not page due verification jobs", st)
			}
			rows, err := paged.ListDueVerificationJobsPage(context.Background(), now, 4096, 0)
			if err != nil {
				t.Fatalf("list: %v", err)
			}
			if len(rows) != 10 {
				t.Fatalf("rows = %d, want 10", len(rows))
			}
			if cap(rows) > verificationDuePageHint {
				t.Fatalf("page cap = %d for 10 rows, want <= %d (limit must not size the page)", cap(rows), verificationDuePageHint)
			}
		})
	}
}

// BenchmarkListDueVerificationJobsPage measures allocs/op for the scheduler's
// poll against the live-isolated Postgres fixture with a realistic due count.
func BenchmarkListDueVerificationJobsPage(b *testing.B) {
	s := testPostgresStore(b)
	ctx := context.Background()
	if _, err := s.pool.Exec(ctx, "TRUNCATE provider_verification_jobs"); err != nil {
		b.Fatalf("truncate: %v", err)
	}
	now := time.Date(2026, 9, 3, 12, 0, 0, 0, time.UTC)
	const due = 64
	seedDueVerificationJobs(b, s, "bench", due, now)

	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		rows, err := s.ListDueVerificationJobsPage(ctx, now, 4096, 0)
		if err != nil {
			b.Fatal(err)
		}
		if len(rows) != due {
			b.Fatalf("rows = %d, want %d", len(rows), due)
		}
	}
}
