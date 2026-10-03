package postgres

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

type verificationJobStore interface {
	UpsertVerificationJob(context.Context, store.VerificationJob) (store.VerificationJob, error)
	GetVerificationJob(context.Context, string, store.VerificationTaskKind) (*store.VerificationJob, error)
	ListDueVerificationJobs(context.Context, time.Time, int) ([]store.VerificationJob, error)
	ClaimVerificationJob(context.Context, string, store.VerificationTaskKind, string, time.Time, time.Time) (store.VerificationJob, bool, error)
	ReleaseVerificationJob(context.Context, string, store.VerificationTaskKind, string, time.Time) error
	CompleteVerificationJob(context.Context, string, store.VerificationTaskKind, string, store.VerificationOutcome, time.Time) error
	RescheduleVerificationJob(context.Context, string, store.VerificationTaskKind, string, store.VerificationPriority, int, time.Duration, time.Time, store.VerificationOutcome, time.Time) error
}

func TestPostgresVerificationSchedulerMigrationIsIdempotent(t *testing.T) {
	st := testPostgresStore(t)
	if _, err := st.pool.Exec(
		context.Background(),
		`ALTER TABLE code_attest_push_budgets
		 DROP CONSTRAINT IF EXISTS code_attest_push_budgets_pkey`,
	); err != nil {
		t.Fatalf("drop composite budget key: %v", err)
	}
	if _, err := st.pool.Exec(
		context.Background(),
		`ALTER TABLE code_attest_push_budgets
		 ADD CONSTRAINT code_attest_push_budgets_pkey PRIMARY KEY (se_pubkey)`,
	); err != nil {
		t.Fatalf("install legacy budget key: %v", err)
	}
	if err := st.migrate(context.Background()); err != nil {
		t.Fatalf("second scheduler migration: %v", err)
	}
	if err := st.migrate(context.Background()); err != nil {
		t.Fatalf("third scheduler migration: %v", err)
	}
	var compositeBudgetKey bool
	err := st.pool.QueryRow(context.Background(), `
		SELECT EXISTS (
			SELECT 1
			  FROM pg_constraint c
			 WHERE c.conrelid = 'code_attest_push_budgets'::regclass
			   AND c.contype = 'p'
			   AND (
				SELECT array_agg(a.attname::TEXT ORDER BY k.ordinality)
				  FROM unnest(c.conkey)
				    WITH ORDINALITY AS k(attnum, ordinality)
				  JOIN pg_attribute a
				    ON a.attrelid = c.conrelid AND a.attnum = k.attnum
			   ) = ARRAY['se_pubkey', 'token_hash']::TEXT[]
		)`).Scan(&compositeBudgetKey)
	if err != nil || !compositeBudgetKey {
		t.Fatalf(
			"code-attest budget primary key is not (se_pubkey, token_hash): ok=%v err=%v",
			compositeBudgetKey, err,
		)
	}
}
