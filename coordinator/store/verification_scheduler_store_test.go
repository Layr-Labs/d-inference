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
	if last, cleared, err := st.ClearCodeAttestPushFloor(
		ctx, "se", now.Add(time.Minute), 20*time.Minute,
	); err != nil || !cleared || !last.Equal(now.Add(time.Minute)) {
		t.Fatalf("first floor clear was not honored: last=%v cleared=%v err=%v", last, cleared, err)
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
	if _, cleared, err := st.ClearCodeAttestPushFloor(
		context.Background(), seKey, now.Add(time.Minute), 20*time.Minute,
	); err != nil || !cleared {
		t.Fatalf("Postgres floor clear was not honored: cleared=%v err=%v", cleared, err)
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

// exerciseCodeAttestPushDistinctNovelTokenRace reproduces the blue-green
// double-admission (Codex P1 follow-up): two coordinators racing DISTINCT
// novel tokens for one SE key — before any floor sentinel exists — must admit
// exactly one, because admission is serialized on the sentinel row itself.
// Repeated iterations alternate the launch order of the two tokens.
func exerciseCodeAttestPushDistinctNovelTokenRace(
	t *testing.T, st codeAttestPushBudgetTestStore, prefix string, iterations int,
) {
	t.Helper()
	ctx := context.Background()
	for iter := range iterations {
		// Truncate to Postgres timestamptz precision: Linux clocks carry
		// nanoseconds, pgx encodes microseconds, and the round-trip Equal
		// below fails only on CI otherwise (macOS clocks tick in µs).
		now := time.Now().UTC().Truncate(time.Microsecond)
		seKey := fmt.Sprintf("%s-%d-%d", prefix, now.UnixNano(), iter)
		hashes := []string{"novel-token-a", "novel-token-b"}
		if iter%2 == 1 { // both orderings
			hashes[0], hashes[1] = hashes[1], hashes[0]
		}
		var admitted atomic.Int32
		var wg sync.WaitGroup
		start := make(chan struct{})
		for _, hash := range hashes {
			wg.Add(1)
			go func() {
				defer wg.Done()
				<-start
				ok, err := st.ReserveCodeAttestPushBudget(
					ctx, seKey, hash, now, now.Add(20*time.Minute),
				)
				if err != nil {
					t.Errorf("iter %d reserve %s: %v", iter, hash, err)
					return
				}
				if ok {
					admitted.Add(1)
				}
			}()
		}
		close(start)
		wg.Wait()
		if got := admitted.Load(); got != 1 {
			t.Fatalf("iter %d: distinct novel tokens admitted = %d, want 1", iter, got)
		}
		// The loser must stay floor-blocked, and durable state must hold
		// exactly the winner's token row plus the raised floor sentinel.
		if ok, err := st.ReserveCodeAttestPushBudget(
			ctx, seKey, "novel-token-c", now.Add(time.Minute),
			now.Add(21*time.Minute),
		); err != nil || ok {
			t.Fatalf("iter %d: third novel token bypassed the floor: ok=%v err=%v", iter, ok, err)
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
				if !row.NextPushAt.Equal(now.Add(20 * time.Minute)) {
					t.Fatalf("iter %d: floor sentinel window = %+v", iter, row)
				}
			} else {
				tokenRows++
			}
		}
		if tokenRows != 1 || floorRows != 1 {
			t.Fatalf("iter %d: budget rows tokens=%d floors=%d, want 1/1", iter, tokenRows, floorRows)
		}
	}
}

func TestMemoryCodeAttestPushDistinctNovelTokensAdmitExactlyOne(t *testing.T) {
	exerciseCodeAttestPushDistinctNovelTokenRace(
		t, NewMemory(Config{}), "race-memory", 32,
	)
}

func TestPostgresCodeAttestPushDistinctNovelTokensAdmitExactlyOne(t *testing.T) {
	exerciseCodeAttestPushDistinctNovelTokenRace(
		t, testPostgresStore(t), "race-postgres", 24,
	)
}

type codeAttestPushBudgetTestStore interface {
	ReserveCodeAttestPushBudget(
		ctx context.Context, seKey, tokenHash string,
		now, nextPushAt time.Time,
	) (bool, error)
	ClearCodeAttestPushFloor(
		ctx context.Context, seKey string,
		now time.Time, cooldown time.Duration,
	) (time.Time, bool, error)
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
	if _, cleared, err := st.ClearCodeAttestPushFloor(
		ctx, seKey, at, 20*time.Minute,
	); err != nil || !cleared {
		t.Fatalf("floor clear was not honored: cleared=%v err=%v", cleared, err)
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

// exerciseCodeAttestPushFloorClearCooldownIsDurable proves the Codex 06:36Z P1
// store contract: the rotation floor clear is compare-and-set on the sentinel's
// durable last-clear instant. The store methods hold no per-caller state, so a
// second clear within the cooldown models a coordinator restart or blue-green
// peer exactly — it must be refused even though the caller "forgot" the first
// clear, and honored again only once the durable cooldown has elapsed.
func exerciseCodeAttestPushFloorClearCooldownIsDurable(
	t *testing.T, st codeAttestPushBudgetTestStore, seKey string,
) {
	t.Helper()
	ctx := context.Background()
	cooldown := 20 * time.Minute
	// µs-truncated for lossless Postgres round-trip equality (see the novel
	// token race exercise).
	now := time.Now().UTC().Truncate(time.Microsecond)
	if ok, err := st.ReserveCodeAttestPushBudget(
		ctx, seKey, "hash-a", now, now.Add(cooldown),
	); err != nil || !ok {
		t.Fatalf("initial admission: ok=%v err=%v", ok, err)
	}
	// First genuine rotation (never cleared before) is honored immediately.
	clearAt := now.Add(time.Minute)
	if last, cleared, err := st.ClearCodeAttestPushFloor(
		ctx, seKey, clearAt, cooldown,
	); err != nil || !cleared || !last.Equal(clearAt) {
		t.Fatalf("first clear: last=%v cleared=%v err=%v", last, cleared, err)
	}
	// The rotated token spends the lifted floor and re-raises it.
	if ok, err := st.ReserveCodeAttestPushBudget(
		ctx, seKey, "hash-b", now.Add(2*time.Minute),
		now.Add(2*time.Minute).Add(cooldown),
	); err != nil || !ok {
		t.Fatalf("rotated token after clear: ok=%v err=%v", ok, err)
	}
	// A restarted/peer instance retrying the clear within the cooldown is
	// refused and told the durable last-clear instant.
	if last, cleared, err := st.ClearCodeAttestPushFloor(
		ctx, seKey, now.Add(3*time.Minute), cooldown,
	); err != nil || cleared || !last.Equal(clearAt) {
		t.Fatalf("in-window clear was not refused: last=%v cleared=%v err=%v", last, cleared, err)
	}
	// ...and the refused clear left the re-raised floor intact: a novel token
	// stays blocked.
	if ok, err := st.ReserveCodeAttestPushBudget(
		ctx, seKey, "hash-c", now.Add(4*time.Minute),
		now.Add(4*time.Minute).Add(cooldown),
	); err != nil || ok {
		t.Fatalf("refused clear still admitted a novel token: ok=%v err=%v", ok, err)
	}
	// Once the durable cooldown elapses, the next rotation clear is honored.
	lateClear := clearAt.Add(cooldown)
	if last, cleared, err := st.ClearCodeAttestPushFloor(
		ctx, seKey, lateClear, cooldown,
	); err != nil || !cleared || !last.Equal(lateClear) {
		t.Fatalf("post-cooldown clear: last=%v cleared=%v err=%v", last, cleared, err)
	}
	if ok, err := st.ReserveCodeAttestPushBudget(
		ctx, seKey, "hash-c", lateClear.Add(time.Minute),
		lateClear.Add(time.Minute).Add(cooldown),
	); err != nil || !ok {
		t.Fatalf("novel token blocked after honored post-cooldown clear: ok=%v err=%v", ok, err)
	}
}

func TestMemoryCodeAttestPushFloorClearCooldownIsDurable(t *testing.T) {
	exerciseCodeAttestPushFloorClearCooldownIsDurable(
		t, NewMemory(Config{}),
		fmt.Sprintf("clear-cooldown-memory-%d", time.Now().UnixNano()),
	)
}

func TestPostgresCodeAttestPushFloorClearCooldownIsDurable(t *testing.T) {
	exerciseCodeAttestPushFloorClearCooldownIsDurable(
		t, testPostgresStore(t),
		fmt.Sprintf("clear-cooldown-postgres-%d", time.Now().UnixNano()),
	)
}

// exerciseCodeAttestPushFloorClearRace: two coordinators (blue-green overlap)
// racing the same rotation clear admit exactly one within the window — the
// durable CAS, not process-local state, is the arbiter.
func exerciseCodeAttestPushFloorClearRace(
	t *testing.T, st codeAttestPushBudgetTestStore, seKey string,
) {
	t.Helper()
	ctx := context.Background()
	cooldown := 20 * time.Minute
	now := time.Now().UTC()
	if ok, err := st.ReserveCodeAttestPushBudget(
		ctx, seKey, "hash-a", now, now.Add(cooldown),
	); err != nil || !ok {
		t.Fatalf("initial admission: ok=%v err=%v", ok, err)
	}
	var honored atomic.Int32
	var wg sync.WaitGroup
	start := make(chan struct{})
	for range 16 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			_, cleared, err := st.ClearCodeAttestPushFloor(
				ctx, seKey, now.Add(time.Minute), cooldown,
			)
			if err != nil {
				t.Errorf("clear: %v", err)
				return
			}
			if cleared {
				honored.Add(1)
			}
		}()
	}
	close(start)
	wg.Wait()
	if honored.Load() != 1 {
		t.Fatalf("concurrent rotation clears honored = %d, want 1", honored.Load())
	}
}

func TestMemoryCodeAttestPushFloorClearRaceAdmitsExactlyOne(t *testing.T) {
	exerciseCodeAttestPushFloorClearRace(
		t, NewMemory(Config{}),
		fmt.Sprintf("clear-race-memory-%d", time.Now().UnixNano()),
	)
}

func TestPostgresCodeAttestPushFloorClearRaceAdmitsExactlyOne(t *testing.T) {
	exerciseCodeAttestPushFloorClearRace(
		t, testPostgresStore(t),
		fmt.Sprintf("clear-race-postgres-%d", time.Now().UnixNano()),
	)
}
