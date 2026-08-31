package store

import (
	"context"
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type verificationJobStore interface {
	UpsertVerificationJob(context.Context, VerificationJob) (VerificationJob, error)
	GetVerificationJob(context.Context, string, VerificationTaskKind) (*VerificationJob, error)
	ListDueVerificationJobs(context.Context, time.Time, int) ([]VerificationJob, error)
	ClaimVerificationJob(context.Context, string, VerificationTaskKind, string, time.Time, time.Time) (VerificationJob, bool, error)
	ReleaseVerificationJob(context.Context, string, VerificationTaskKind, string, time.Time) error
	CompleteVerificationJob(context.Context, string, VerificationTaskKind, string, VerificationOutcome, time.Time) error
	RescheduleVerificationJob(context.Context, string, VerificationTaskKind, string, VerificationPriority, int, time.Duration, time.Time, VerificationOutcome, time.Time) error
}

func exerciseVerificationJobStore(t *testing.T, st verificationJobStore, prefix string) {
	t.Helper()
	ctx := context.Background()
	now := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	seRecovery := prefix + "-recovery"
	seFirst := prefix + "-first"
	seRefresh := prefix + "-refresh"
	for _, rec := range []VerificationJob{
		{SEPubKey: seRefresh, Serial: "r", Kind: VerificationTaskSecurityInfo, State: VerificationStateBackoff, Priority: VerificationPriorityRefresh, RetryStage: 2, PreviousDelay: 9 * time.Minute, NextAttemptAt: now.Add(-time.Minute), LastOutcome: VerificationOutcomeTimeout, UpdatedAt: now},
		{SEPubKey: seRecovery, Serial: "x", Kind: VerificationTaskSecurityInfo, State: VerificationStatePending, Priority: VerificationPriorityRecovery, NextAttemptAt: now.Add(-2 * time.Minute), UpdatedAt: now},
		{SEPubKey: seFirst, Serial: "f", Kind: VerificationTaskSecurityInfo, State: VerificationStatePending, Priority: VerificationPriorityFirstOrExpired, NextAttemptAt: now.Add(-time.Second), UpdatedAt: now},
	} {
		if _, err := st.UpsertVerificationJob(ctx, rec); err != nil {
			t.Fatalf("upsert %s: %v", rec.SEPubKey, err)
		}
	}

	// Reconnect upsert may refresh identity fields but cannot reset durable retry
	// stage, state, due time, or prior outcome.
	got, err := st.UpsertVerificationJob(ctx, VerificationJob{
		SEPubKey: seRefresh, Serial: "r2", UDID: "u2",
		Kind: VerificationTaskSecurityInfo, State: VerificationStateWaitingChallenge,
		Priority: VerificationPriorityRefresh, UpdatedAt: now.Add(time.Second),
	})
	if err != nil {
		t.Fatal(err)
	}
	if got.State != VerificationStateBackoff || got.RetryStage != 2 || got.PreviousDelay != 9*time.Minute || !got.NextAttemptAt.Equal(now.Add(-time.Minute)) || got.LastOutcome != VerificationOutcomeTimeout {
		t.Fatalf("reconnect reset durable retry state: %+v", got)
	}
	if got.Serial != "r2" || got.UDID != "u2" {
		t.Fatalf("reconnect did not refresh identity metadata: %+v", got)
	}

	due, err := st.ListDueVerificationJobs(ctx, now, 10000)
	if err != nil {
		t.Fatal(err)
	}
	positions := map[string]int{}
	for i, rec := range due {
		if rec.SEPubKey == seFirst || rec.SEPubKey == seRecovery || rec.SEPubKey == seRefresh {
			positions[rec.SEPubKey] = i
		}
	}
	if len(positions) != 3 {
		t.Fatalf("due rows missing: %#v", positions)
	}
	if !(positions[seFirst] < positions[seRecovery] && positions[seRecovery] < positions[seRefresh]) {
		t.Fatalf("due priority order = %#v", positions)
	}

	claim, ok, err := st.ClaimVerificationJob(ctx, seRecovery, VerificationTaskSecurityInfo, "owner-a", now, now.Add(time.Minute))
	if err != nil || !ok || claim.State != VerificationStateRunning || claim.ClaimOwner != "owner-a" {
		t.Fatalf("first claim = %+v, %v, %v", claim, ok, err)
	}
	if _, ok, err := st.ClaimVerificationJob(ctx, seRecovery, VerificationTaskSecurityInfo, "owner-b", now.Add(30*time.Second), now.Add(2*time.Minute)); err != nil || ok {
		t.Fatalf("live claim stolen: ok=%v err=%v", ok, err)
	}
	claim, ok, err = st.ClaimVerificationJob(ctx, seRecovery, VerificationTaskSecurityInfo, "owner-b", now.Add(61*time.Second), now.Add(3*time.Minute))
	if err != nil || !ok || claim.ClaimOwner != "owner-b" {
		t.Fatalf("expired claim not acquired: %+v, %v, %v", claim, ok, err)
	}

	next := now.Add(20 * time.Minute)
	if err := st.RescheduleVerificationJob(ctx, seRecovery, VerificationTaskSecurityInfo, "owner-b", VerificationPriorityRecovery, 3, 20*time.Minute, next, VerificationOutcomeTransient, now.Add(62*time.Second)); err != nil {
		t.Fatal(err)
	}
	gotPtr, err := st.GetVerificationJob(ctx, seRecovery, VerificationTaskSecurityInfo)
	if err != nil || gotPtr == nil || gotPtr.State != VerificationStateBackoff || gotPtr.RetryStage != 3 || !gotPtr.NextAttemptAt.Equal(next) || gotPtr.ClaimOwner != "" {
		t.Fatalf("reschedule state = %+v, err=%v", gotPtr, err)
	}
	if err := st.CompleteVerificationJob(ctx, seRecovery, VerificationTaskSecurityInfo, "", VerificationOutcomeSuccess, now.Add(2*time.Minute)); err != nil {
		t.Fatal(err)
	}
	gotPtr, err = st.GetVerificationJob(ctx, seRecovery, VerificationTaskSecurityInfo)
	if err != nil || gotPtr == nil || gotPtr.State != VerificationStateCompleted || gotPtr.LastOutcome != VerificationOutcomeSuccess || !gotPtr.NextAttemptAt.IsZero() {
		t.Fatalf("completion state = %+v, err=%v", gotPtr, err)
	}
	reopened, err := st.UpsertVerificationJob(ctx, VerificationJob{
		SEPubKey: seRecovery, Serial: "x", Kind: VerificationTaskSecurityInfo,
		State: VerificationStateWaitingChallenge, Priority: VerificationPriorityRefresh,
		UpdatedAt: now.Add(3 * time.Minute),
	})
	if err != nil {
		t.Fatal(err)
	}
	if reopened.State != VerificationStateWaitingChallenge ||
		reopened.Priority != VerificationPriorityRefresh ||
		reopened.RetryStage != 0 ||
		!reopened.NextAttemptAt.IsZero() {
		t.Fatalf("completed refresh reopen retained historical scheduling state: %+v", reopened)
	}

	seRebind := prefix + "-rebind"
	if _, err := st.UpsertVerificationJob(ctx, VerificationJob{
		SEPubKey: seRebind, Serial: "rb", Kind: VerificationTaskSecurityInfo,
		State: VerificationStatePending, Priority: VerificationPriorityRecovery,
		RetryStage: 2, PreviousDelay: 9 * time.Minute,
		NextAttemptAt: now, LastOutcome: VerificationOutcomeTimeout, UpdatedAt: now,
	}); err != nil {
		t.Fatal(err)
	}
	if _, ok, err := st.ClaimVerificationJob(
		ctx, seRebind, VerificationTaskSecurityInfo, "owner-old",
		now, now.Add(time.Minute),
	); err != nil || !ok {
		t.Fatalf("claim cross-instance row: ok=%v err=%v", ok, err)
	}
	rebindDue := now.Add(5 * time.Second)
	marked, err := st.UpsertVerificationJob(ctx, VerificationJob{
		SEPubKey: seRebind, Serial: "rb", Kind: VerificationTaskSecurityInfo,
		State: VerificationStatePending, Priority: VerificationPriorityRecovery,
		NextAttemptAt: rebindDue, UpdatedAt: now.Add(time.Second),
	})
	if err != nil {
		t.Fatal(err)
	}
	if marked.State != VerificationStateRunning || !marked.ReopenPending ||
		marked.RetryStage != 2 || marked.PreviousDelay != 9*time.Minute {
		t.Fatalf("replacement challenge did not preserve claimed retry state: %+v", marked)
	}
	if err := st.CompleteVerificationJob(
		ctx, seRebind, VerificationTaskSecurityInfo, "owner-old",
		VerificationOutcomeSuccess, now.Add(2*time.Second),
	); err != nil {
		t.Fatal(err)
	}
	rebound, err := st.GetVerificationJob(ctx, seRebind, VerificationTaskSecurityInfo)
	if err != nil || rebound == nil || rebound.State != VerificationStatePending ||
		rebound.ReopenPending || rebound.ClaimOwner != "" ||
		rebound.RetryStage != 2 || rebound.PreviousDelay != 9*time.Minute ||
		!rebound.NextAttemptAt.Equal(rebindDue) ||
		rebound.LastOutcome != VerificationOutcomeTimeout {
		t.Fatalf("old completion stranded or reset replacement work: %+v, err=%v", rebound, err)
	}
	if _, ok, err := st.ClaimVerificationJob(
		ctx, seRebind, VerificationTaskSecurityInfo, "owner-transient",
		now.Add(6*time.Second), now.Add(time.Minute),
	); err != nil || !ok {
		t.Fatalf("claim transient cross-instance row: ok=%v err=%v", ok, err)
	}
	transientRebindDue := now.Add(10 * time.Second)
	marked, err = st.UpsertVerificationJob(ctx, VerificationJob{
		SEPubKey: seRebind, Serial: "rb", Kind: VerificationTaskSecurityInfo,
		State: VerificationStatePending, Priority: VerificationPriorityRecovery,
		NextAttemptAt: transientRebindDue, UpdatedAt: now.Add(7 * time.Second),
	})
	if err != nil || !marked.ReopenPending {
		t.Fatalf("transient replacement challenge did not mark reopen: %+v, err=%v", marked, err)
	}
	if err := st.RescheduleVerificationJob(
		ctx, seRebind, VerificationTaskSecurityInfo, "owner-transient",
		VerificationPriorityRecovery, 3, 20*time.Minute,
		now.Add(20*time.Minute), VerificationOutcomeTransient,
		now.Add(8*time.Second),
	); err != nil {
		t.Fatal(err)
	}
	rebound, err = st.GetVerificationJob(ctx, seRebind, VerificationTaskSecurityInfo)
	if err != nil || rebound == nil || rebound.State != VerificationStatePending ||
		rebound.ReopenPending || rebound.ClaimOwner != "" ||
		rebound.RetryStage != 2 || rebound.PreviousDelay != 9*time.Minute ||
		!rebound.NextAttemptAt.Equal(transientRebindDue) ||
		rebound.LastOutcome != VerificationOutcomeTimeout {
		t.Fatalf("old transient result overwrote replacement work: %+v, err=%v", rebound, err)
	}
}

func TestMemoryVerificationSchedulerCRUDClaimsAndOrdering(t *testing.T) {
	exerciseVerificationJobStore(t, NewMemory(Config{}), fmt.Sprintf("memory-%d", time.Now().UnixNano()))
}

func TestPostgresVerificationSchedulerCRUDClaimsAndOrdering(t *testing.T) {
	exerciseVerificationJobStore(t, testPostgresStore(t), fmt.Sprintf("postgres-%d", time.Now().UnixNano()))
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

func TestMemoryCodeAttestPushAdmissionIsAtomicAndRestartSeedable(t *testing.T) {
	st := NewMemory(Config{})
	ctx := context.Background()
	now := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	var admitted atomic.Int32
	var wg sync.WaitGroup
	for range 64 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			ok, err := st.ReserveCodeAttestPushBudget(ctx, "se", "token-hash", now, now.Add(20*time.Minute))
			if err != nil {
				t.Errorf("reserve: %v", err)
			}
			if ok {
				admitted.Add(1)
			}
		}()
	}
	wg.Wait()
	if admitted.Load() != 1 {
		t.Fatalf("atomic admissions = %d, want 1", admitted.Load())
	}
	rows, err := st.ListCodeAttestPushBudgets(ctx)
	if err != nil || len(rows) != 2 { // token row + admission-floor sentinel
		t.Fatalf("persisted budget = %+v, err=%v", rows, err)
	}
	for _, row := range rows {
		if !row.NextPushAt.Equal(now.Add(20 * time.Minute)) {
			t.Fatalf("persisted budget window = %+v", row)
		}
	}
	if ok, err := st.ReserveCodeAttestPushBudget(
		ctx, "se", "token-hash", now.Add(time.Minute),
		now.Add(21*time.Minute),
	); err != nil || ok {
		t.Fatalf("same-token cooldown was bypassed: ok=%v err=%v", ok, err)
	}
	// A NOVEL token inside the admission floor must wait (Codex P1)...
	if ok, err := st.ReserveCodeAttestPushBudget(
		ctx, "se", "rotated-token-hash", now.Add(time.Minute),
		now.Add(21*time.Minute),
	); err != nil || ok {
		t.Fatalf("novel token bypassed the admission floor: ok=%v err=%v", ok, err)
	}
	// ...unless a genuine rotation lifted the floor.
	if err := st.ClearCodeAttestPushFloor(ctx, "se"); err != nil {
		t.Fatal(err)
	}
	if ok, err := st.ReserveCodeAttestPushBudget(
		ctx, "se", "rotated-token-hash", now.Add(time.Minute),
		now.Add(21*time.Minute),
	); err != nil || !ok {
		t.Fatalf("rotated token was not admitted after floor clear: ok=%v err=%v", ok, err)
	}
	if ok, err := st.ReserveCodeAttestPushBudget(
		ctx, "se", "rotated-token-hash", now.Add(2*time.Minute),
		now.Add(22*time.Minute),
	); err != nil || ok {
		t.Fatalf("rotated-token cooldown was bypassed: ok=%v err=%v", ok, err)
	}
	if ok, err := st.ReserveCodeAttestPushBudget(
		ctx, "se", "token-hash", now.Add(3*time.Minute),
		now.Add(23*time.Minute),
	); err != nil || ok {
		t.Fatalf("token A cooldown was forgotten after A-B-A rotation: ok=%v err=%v", ok, err)
	}
	rows, err = st.ListCodeAttestPushBudgets(ctx)
	if err != nil || len(rows) != 3 { // two token rows + re-raised floor sentinel
		t.Fatalf("per-token budgets = %+v, err=%v", rows, err)
	}
}

func TestPostgresCodeAttestPushAdmissionIsAtomic(t *testing.T) {
	st := testPostgresStore(t)
	now := time.Now().UTC()
	seKey := fmt.Sprintf("push-postgres-%d", now.UnixNano())
	syntaxKey := seKey + "-syntax"
	ok, err := st.ReserveCodeAttestPushBudget(
		context.Background(), syntaxKey, "token-hash",
		now, now.Add(20*time.Minute),
	)
	if err != nil || !ok {
		t.Fatalf("Postgres reservation SQL did not execute: ok=%v err=%v", ok, err)
	}
	var admitted atomic.Int32
	var wg sync.WaitGroup
	for range 32 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			ok, err := st.ReserveCodeAttestPushBudget(
				context.Background(), seKey, "token-hash",
				now, now.Add(20*time.Minute),
			)
			if err != nil {
				t.Errorf("reserve: %v", err)
				return
			}
			if ok {
				admitted.Add(1)
			}
		}()
	}
	wg.Wait()
	if admitted.Load() != 1 {
		t.Fatalf("Postgres atomic admissions = %d, want 1", admitted.Load())
	}
	// A novel token inside the admission floor waits (Codex P1); a genuine
	// rotation lifts the floor and admits it promptly.
	if ok, err := st.ReserveCodeAttestPushBudget(
		context.Background(), seKey, "rotated-token-hash",
		now.Add(time.Minute), now.Add(21*time.Minute),
	); err != nil || ok {
		t.Fatalf("Postgres novel token bypassed the admission floor: ok=%v err=%v", ok, err)
	}
	if err := st.ClearCodeAttestPushFloor(context.Background(), seKey); err != nil {
		t.Fatal(err)
	}
	if ok, err := st.ReserveCodeAttestPushBudget(
		context.Background(), seKey, "rotated-token-hash",
		now.Add(time.Minute), now.Add(21*time.Minute),
	); err != nil || !ok {
		t.Fatalf("Postgres rotated token was not admitted after floor clear: ok=%v err=%v", ok, err)
	}
	if ok, err := st.ReserveCodeAttestPushBudget(
		context.Background(), seKey, "token-hash",
		now.Add(2*time.Minute), now.Add(22*time.Minute),
	); err != nil || ok {
		t.Fatalf("Postgres token A cooldown was forgotten after A-B-A rotation: ok=%v err=%v", ok, err)
	}
}

type codeAttestPushBudgetTestStore interface {
	ReserveCodeAttestPushBudget(
		ctx context.Context, seKey, tokenHash string,
		now, nextPushAt time.Time,
	) (bool, error)
	ClearCodeAttestPushFloor(ctx context.Context, seKey string) error
	ListCodeAttestPushBudgets(ctx context.Context) ([]CodeAttestPushBudget, error)
}

// exerciseCodeAttestPushBudgetFloorAndCap proves the Codex P1 store contract:
// novel tokens are paced by the per-SE-key admission floor, rows per key stay
// capped under token churn, and a floor clear (genuine rotation) admits
// exactly the next novel token promptly.
func exerciseCodeAttestPushBudgetFloorAndCap(
	t *testing.T, st codeAttestPushBudgetTestStore, seKey string,
) {
	t.Helper()
	ctx := context.Background()
	step := 20 * time.Minute
	at := time.Now().UTC()
	for i := range 2 * CodeAttestPushBudgetMaxTokenRows {
		hash := fmt.Sprintf("hash-%02d", i)
		if ok, err := st.ReserveCodeAttestPushBudget(
			ctx, seKey, hash, at, at.Add(step),
		); err != nil || !ok {
			t.Fatalf("floor-paced novel admission %d: ok=%v err=%v", i, ok, err)
		}
		if ok, err := st.ReserveCodeAttestPushBudget(
			ctx, seKey, hash+"-burst", at.Add(time.Minute),
			at.Add(time.Minute).Add(step),
		); err != nil || ok {
			t.Fatalf("burst novel token bypassed the floor at %d: ok=%v err=%v", i, ok, err)
		}
		at = at.Add(step)
	}
	rows, err := st.ListCodeAttestPushBudgets(ctx)
	if err != nil {
		t.Fatal(err)
	}
	tokenRows, floorRows := 0, 0
	for _, row := range rows {
		if row.SEPubKey != seKey {
			continue
		}
		if row.TokenHash == "" {
			floorRows++
		} else {
			tokenRows++
		}
	}
	if tokenRows > CodeAttestPushBudgetMaxTokenRows || floorRows != 1 {
		t.Fatalf("budget rows unbounded: tokens=%d floors=%d", tokenRows, floorRows)
	}
	if err := st.ClearCodeAttestPushFloor(ctx, seKey); err != nil {
		t.Fatal(err)
	}
	if ok, err := st.ReserveCodeAttestPushBudget(
		ctx, seKey, "rotated-hash", at.Add(time.Minute),
		at.Add(time.Minute).Add(step),
	); err != nil || !ok {
		t.Fatalf("cleared floor did not admit the rotated token: ok=%v err=%v", ok, err)
	}
}

func TestMemoryCodeAttestPushBudgetFloorAndCap(t *testing.T) {
	exerciseCodeAttestPushBudgetFloorAndCap(
		t, NewMemory(Config{}),
		fmt.Sprintf("floor-memory-%d", time.Now().UnixNano()),
	)
}

func TestPostgresCodeAttestPushBudgetFloorAndCap(t *testing.T) {
	exerciseCodeAttestPushBudgetFloorAndCap(
		t, testPostgresStore(t),
		fmt.Sprintf("floor-postgres-%d", time.Now().UnixNano()),
	)
}
