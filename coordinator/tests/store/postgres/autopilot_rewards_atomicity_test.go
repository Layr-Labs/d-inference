package postgres_test

import (
	"context"
	"errors"
	"math"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/payments/floorpolicy"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
)

const autopilotFinancialSnapshotSQL = `SELECT jsonb_build_object(
 'pool',(SELECT jsonb_agg(to_jsonb(t)) FROM autopilot_reward_pool t),
 'balances',(SELECT jsonb_agg(to_jsonb(t) ORDER BY account_id) FROM balances t),
 'ledger',(SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM ledger_entries t),
 'earnings',(SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM provider_earnings t),
 'summary',(SELECT jsonb_agg(to_jsonb(t) ORDER BY key,key_type) FROM earnings_summary t),
 'enrollments',(SELECT jsonb_agg(to_jsonb(t) ORDER BY machine_id) FROM autopilot_reward_enrollments t),
 'receipts',(SELECT jsonb_agg(to_jsonb(t) ORDER BY machine_id,day) FROM autopilot_reward_settlements t),
 'base_rewards',(SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM provider_floor_draws t)
)::text`

func TestAutopilotRewardsSettlementRollsBackEveryFinancialWrite(t *testing.T) {
	for _, target := range []string{"ledger_entries", "earnings_summary", "autopilot_reward_settlements", "suppressed_ledger"} {
		t.Run(target, func(t *testing.T) {
			f := newAutopilotRewardsFixture(t)
			ctx := t.Context()
			first := f.firstSeen.Add(8*24*time.Hour + 12*time.Hour)
			enrollment := f.enroll(t, "owner", "provider", first, 70)
			if _, err := f.SetAutopilotRewardPoolCap(ctx, 11); err != nil {
				t.Fatal(err)
			}
			table, body := target, "RAISE EXCEPTION 'reward transaction rollback';"
			if target == "suppressed_ledger" {
				table, body = "ledger_entries", "RETURN NULL;"
			}
			if _, err := f.pool.Exec(ctx, `CREATE FUNCTION reject_autopilot_reward() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN `+body+` END $$`); err != nil {
				t.Fatal(err)
			}
			if _, err := f.pool.Exec(ctx, `CREATE TRIGGER reject_autopilot_reward BEFORE INSERT OR UPDATE ON `+table+` FOR EACH ROW EXECUTE FUNCTION reject_autopilot_reward()`); err != nil {
				t.Fatal(err)
			}
			before := queryLines(t, f.pool, autopilotFinancialSnapshotSQL)
			if _, err := f.SettleAutopilotRewardDay(ctx, enrollment.MachineID, floorpolicy.Day(first)); err == nil {
				t.Fatal("settlement accepted a failed or suppressed financial write")
			}
			assertSameLines(t, "before failed credit", before, "after rollback", queryLines(t, f.pool, autopilotFinancialSnapshotSQL))
			if _, err := f.pool.Exec(ctx, `DROP TRIGGER reject_autopilot_reward ON `+table); err != nil {
				t.Fatal(err)
			}
			receipt, err := f.SettleAutopilotRewardDay(ctx, enrollment.MachineID, floorpolicy.Day(first))
			if err != nil || receipt.Status != earningsfloor.Paid || receipt.AmountMicroUSD != 11 {
				t.Fatalf("retry after rollback: %+v %v", receipt, err)
			}
		})
	}
}

func TestAutopilotRewardsOverflowDoesNotConsumePoolOrDay(t *testing.T) {
	for _, target := range []string{"balance", "withdrawable", "summary"} {
		t.Run(target, func(t *testing.T) {
			f := newAutopilotRewardsFixture(t)
			ctx := t.Context()
			first := f.firstSeen.Add(8*24*time.Hour + 12*time.Hour)
			enrollment := f.enroll(t, "owner", "provider", first, 70)
			if _, err := f.SetAutopilotRewardPoolCap(ctx, math.MaxInt64); err != nil {
				t.Fatal(err)
			}
			var query string
			switch target {
			case "balance":
				query = `INSERT INTO balances(account_id,balance_micro_usd) VALUES('owner',$1)`
			case "withdrawable":
				query = `INSERT INTO balances(account_id,withdrawable_micro_usd) VALUES('owner',$1)`
			case "summary":
				query = `UPDATE earnings_summary SET total_micro_usd=$1 WHERE key='owner' AND key_type='account'`
			}
			if _, err := f.pool.Exec(ctx, query, int64(math.MaxInt64)); err != nil {
				t.Fatal(err)
			}
			before := queryLines(t, f.pool, autopilotFinancialSnapshotSQL)
			if _, err := f.SettleAutopilotRewardDay(ctx, enrollment.MachineID, floorpolicy.Day(first)); err == nil {
				t.Fatal("overflowing credit succeeded")
			}
			assertSameLines(t, "before overflowing credit", before, "after rollback", queryLines(t, f.pool, autopilotFinancialSnapshotSQL))
		})
	}
}

func TestAutopilotRewardsAdmissionWaitsForDeletionBeforeInventoryAndPool(t *testing.T) {
	f := newAutopilotRewardsFixture(t)
	ctx := t.Context()
	first := f.firstSeen.Add(8*24*time.Hour + 12*time.Hour)
	if err := f.CreateUser(&store.User{AccountID: "owner", PrivyUserID: "did:privy:autopilot-owner"}); err != nil {
		t.Fatal(err)
	}
	enrollment := f.enroll(t, "owner", "provider", first, 70)
	if _, err := f.SetAutopilotRewardPoolCap(ctx, 11); err != nil {
		t.Fatal(err)
	}
	before := queryLines(t, f.pool, autopilotFinancialSnapshotSQL)
	hold, err := f.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer hold.Rollback(ctx)
	if _, err := hold.Exec(ctx, `SELECT account_id FROM users WHERE account_id='owner' FOR UPDATE`); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() {
		_, err := f.SettleAutopilotRewardDay(ctx, enrollment.MachineID, floorpolicy.Day(first))
		done <- err
	}()
	waitErasureLock(t, f.postgresFixture, "SELECT deleted_at FROM users", 1)
	// Deletion can take inventory after its user lock. Settlement must not hold
	// inventory while waiting for that same user, or this would deadlock.
	lockCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	if _, err := hold.Exec(lockCtx, `SELECT pg_advisory_xact_lock(9952701)`); err != nil {
		t.Fatal(err)
	}
	if _, err := hold.Exec(ctx, `UPDATE users SET deleted_at=now() WHERE account_id='owner'`); err != nil {
		t.Fatal(err)
	}
	if err := hold.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	if err := <-done; !errors.Is(err, store.ErrErasureConflict) {
		t.Fatalf("deleted account admitted: %v", err)
	}
	assertSameLines(t, "before deletion", before, "after refused credit", queryLines(t, f.pool, autopilotFinancialSnapshotSQL))
}

func TestAutopilotRewardsErasureMarkerRejectsBeforeCreditTriggers(t *testing.T) {
	f := newAutopilotRewardsFixture(t)
	ctx := t.Context()
	first := f.firstSeen.Add(8*24*time.Hour + 12*time.Hour)
	enrollment := f.enroll(t, "owner", "provider", first, 70)
	if _, err := f.SetAutopilotRewardPoolCap(ctx, 11); err != nil {
		t.Fatal(err)
	}
	// The durable erased marker must fence even an account with no users row;
	// relying only on users.deleted_at lets SQL triggers silently refuse money.
	if _, err := f.pool.Exec(ctx, `INSERT INTO erasure_requests(id,account_id,state,erased_at) VALUES('erased-owner','owner','erased',now())`); err != nil {
		t.Fatal(err)
	}
	before := queryLines(t, f.pool, autopilotFinancialSnapshotSQL)
	if _, err := f.SettleAutopilotRewardDay(ctx, enrollment.MachineID, floorpolicy.Day(first)); !errors.Is(err, store.ErrErasureConflict) {
		t.Fatalf("erased marker allowed settlement: %v", err)
	}
	if _, err := f.ObserveAutopilotConsent(ctx, earningsfloor.Consent{SessionID: "provider", AccountID: "owner", Supported: true, Qualified: true, OptedIn: true, At: first.Add(time.Hour)}); !errors.Is(err, store.ErrErasureConflict) {
		t.Fatalf("erased marker allowed renewed consent: %v", err)
	}
	assertSameLines(t, "before erased account attempts", before, "after refused operations", queryLines(t, f.pool, autopilotFinancialSnapshotSQL))
	var refused int
	if err := f.pool.QueryRow(ctx, `SELECT count(*) FROM erasure_refused_credits`).Scan(&refused); err != nil || refused != 0 {
		t.Fatalf("credit reached suppression trigger: refused=%d %v", refused, err)
	}
}

func TestAutopilotRewardsMergedReceiptsRemainIdempotent(t *testing.T) {
	for _, bothSettled := range []bool{false, true} {
		name := "one_final"
		if bothSettled {
			name = "historical_duplicate"
		}
		t.Run(name, func(t *testing.T) {
			f := newAutopilotRewardsFixture(t)
			ctx := t.Context()
			first := f.firstSeen.Add(8*24*time.Hour + 12*time.Hour)
			a := f.enroll(t, "owner", "a", first, 70)
			b := f.enroll(t, "owner", "b", first.Add(time.Hour), 140)
			if _, err := f.SetAutopilotRewardPoolCap(ctx, 100); err != nil {
				t.Fatal(err)
			}
			day := floorpolicy.Day(first)
			paid, err := f.SettleAutopilotRewardDay(ctx, a.MachineID, day)
			if err != nil || paid.AmountMicroUSD != 11 {
				t.Fatalf("first payment: %+v %v", paid, err)
			}
			if bothSettled {
				if _, err := f.SettleAutopilotRewardDay(ctx, b.MachineID, day); err != nil {
					t.Fatal(err)
				}
			}
			for _, session := range []string{"a", "b"} {
				if _, err := f.ObserveMachine(ctx, store.MachineObservation{SessionID: session, AccountID: "owner", SEKey: session, VerifiedSerial: "shared-verified-serial", At: first.Add(48 * time.Hour)}); err != nil {
					t.Fatal(err)
				}
			}
			before := queryLines(t, f.pool, autopilotFinancialSnapshotSQL)
			replay, err := f.SettleAutopilotRewardDay(ctx, b.MachineID, day)
			if bothSettled {
				if !errors.Is(err, earningsfloor.ErrIdentity) {
					t.Fatalf("duplicate historical receipts not flagged: %+v %v", replay, err)
				}
			} else if err != nil || replay != paid {
				t.Fatalf("merged ancestor paid again: %+v %v", replay, err)
			}
			assertSameLines(t, "before merged replay", before, "after merged replay", queryLines(t, f.pool, autopilotFinancialSnapshotSQL))
			rows, err := f.AutopilotRewardEnrollments(ctx, "", 100)
			if err != nil || len(rows) != 1 || rows[0].DailyFloorMicroUSD != 11 || !rows[0].FirstOptInAt.Equal(first) {
				t.Fatalf("merged baseline was summed or changed: %+v %v", rows, err)
			}
		})
	}
}
