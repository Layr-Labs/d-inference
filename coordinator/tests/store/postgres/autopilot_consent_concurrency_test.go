package postgres_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
)

func TestAutopilotConsentJournalSharesInventoryBarrier(t *testing.T) {
	f := newAutopilotRewardsFixture(t)
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	if _, err := f.ObserveMachine(ctx, store.MachineObservation{SessionID: "bound", AccountID: "owner", SEKey: "bound-se", At: f.firstSeen}); err != nil {
		t.Fatal(err)
	}
	hold, err := f.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer hold.Rollback(context.Background())
	if _, err := hold.Exec(ctx, `SELECT pg_advisory_xact_lock_shared(9952701)`); err != nil {
		t.Fatal(err)
	}
	writeCtx, stopWrites := context.WithTimeout(ctx, 3*time.Second)
	defer stopWrites()
	done := make(chan error, 2)
	for _, session := range []string{"bound", "unbound"} {
		go func() {
			done <- f.RecordAutopilotConsent(writeCtx, earningsfloor.Consent{
				SessionID: session, AccountID: "owner", Supported: true, Qualified: true, OptedIn: true, At: f.firstSeen,
			})
		}()
	}
	for range 2 {
		select {
		case err := <-done:
			if err != nil {
				t.Fatalf("shared inventory lock blocked raw consent journal: %v", err)
			}
		case <-writeCtx.Done():
			t.Fatal("shared inventory lock blocked raw consent journal commits")
		}
	}
	var journaled, bound int
	if err := f.pool.QueryRow(ctx, `SELECT count(*),count(machine_id) FROM autopilot_reward_consents WHERE account_id='owner'`).Scan(&journaled, &bound); err != nil {
		t.Fatal(err)
	}
	if journaled != 2 || bound != 1 {
		t.Fatalf("journal commits under shared inventory lock: rows=%d bound=%d, want 2 and 1", journaled, bound)
	}
}

func TestAutopilotConsentJournalWaitsForExclusiveInventoryBarrier(t *testing.T) {
	f := newAutopilotRewardsFixture(t)
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	hold, err := f.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer hold.Rollback(context.Background())
	if _, err := hold.Exec(ctx, `SELECT pg_advisory_xact_lock(9952701)`); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() {
		done <- f.RecordAutopilotConsent(ctx, earningsfloor.Consent{
			SessionID: "exclusive", AccountID: "owner", Supported: true, OptedIn: true, At: f.firstSeen,
		})
	}()
	waitMachineAutopilotLock(t, f.postgresFixture, "pg_advisory_xact_lock_shared(9952701)", 1)
	select {
	case err := <-done:
		t.Fatalf("journal returned before exclusive inventory lock released: %v", err)
	default:
	}
	var journaled int
	if err := f.pool.QueryRow(ctx, `SELECT count(*) FROM autopilot_reward_consents`).Scan(&journaled); err != nil || journaled != 0 {
		t.Fatalf("journal committed through exclusive inventory lock: rows=%d err=%v", journaled, err)
	}
	if err := hold.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-ctx.Done():
		t.Fatal("journal did not resume after exclusive inventory lock released")
	}
	if err := f.pool.QueryRow(ctx, `SELECT count(*) FROM autopilot_reward_consents`).Scan(&journaled); err != nil || journaled != 1 {
		t.Fatalf("journal did not commit after inventory lock release: rows=%d err=%v", journaled, err)
	}
}

func TestAutopilotConsentJournalSerializesSessionOwnership(t *testing.T) {
	f := newAutopilotRewardsFixture(t)
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	hold, err := f.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer hold.Rollback(context.Background())
	if _, err := hold.Exec(ctx, `LOCK TABLE autopilot_reward_consents IN SHARE MODE`); err != nil {
		t.Fatal(err)
	}
	first := earningsfloor.Consent{SessionID: "same-session", AccountID: "first-owner", Supported: true, OptedIn: true, At: f.firstSeen}
	firstDone := make(chan error, 1)
	go func() { firstDone <- f.RecordAutopilotConsent(ctx, first) }()
	// The first owner has passed its ownership reads but has not inserted yet.
	waitMachineAutopilotLock(t, f.postgresFixture, "INSERT INTO autopilot_reward_consents", 1)
	second := first
	second.AccountID, second.At = "second-owner", first.At.Add(time.Hour)
	secondDone := make(chan error, 1)
	go func() { secondDone <- f.RecordAutopilotConsent(ctx, second) }()
	waitMachineAutopilotLock(t, f.postgresFixture, "pg_advisory_xact_lock(hashtext('autopilot-consent')", 1)
	if err := hold.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-firstDone:
		if err != nil {
			t.Fatalf("first session owner failed: %v", err)
		}
	case <-ctx.Done():
		t.Fatal("first session owner did not finish")
	}
	select {
	case err := <-secondDone:
		if !errors.Is(err, earningsfloor.ErrIdentity) {
			t.Fatalf("concurrent session owner change accepted: %v", err)
		}
	case <-ctx.Done():
		t.Fatal("second session owner did not finish")
	}
	var journaled int
	var owner string
	if err := f.pool.QueryRow(ctx, `SELECT count(*),min(account_id) FROM autopilot_reward_consents WHERE session_id=$1`, first.SessionID).Scan(&journaled, &owner); err != nil {
		t.Fatal(err)
	}
	if journaled != 1 || owner != first.AccountID {
		t.Fatalf("session ownership split across journal rows: rows=%d owner=%q", journaled, owner)
	}
}

func TestAutopilotConsentJournalBindsOnlyCurrentSession(t *testing.T) {
	f := newAutopilotRewardsFixture(t)
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	first := earningsfloor.Consent{SessionID: "binding-first", AccountID: "owner", Supported: true, OptedIn: true, At: f.firstSeen}
	second := first
	second.SessionID = "binding-second"
	for _, consent := range []earningsfloor.Consent{first, second} {
		if err := f.RecordAutopilotConsent(ctx, consent); err != nil {
			t.Fatal(err)
		}
	}
	var machineID string
	for _, session := range []string{first.SessionID, second.SessionID} {
		identity, err := f.ObserveMachine(ctx, store.MachineObservation{SessionID: session, AccountID: "owner", SEKey: "shared-se", At: f.firstSeen})
		if err != nil {
			t.Fatal(err)
		}
		if machineID != "" && identity.ID != machineID {
			t.Fatalf("sessions did not resolve to the same machine: %q != %q", identity.ID, machineID)
		}
		machineID = identity.ID
	}
	hold, err := f.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer hold.Rollback(context.Background())
	var lockedSession string
	if err := hold.QueryRow(ctx, `SELECT session_id FROM autopilot_reward_consents
	 WHERE session_id=$1 AND machine_id IS NULL FOR UPDATE`, second.SessionID).Scan(&lockedSession); err != nil {
		t.Fatal(err)
	}
	writeCtx, stopWrite := context.WithTimeout(ctx, 3*time.Second)
	defer stopWrite()
	first.At = first.At.Add(time.Hour)
	if err := f.RecordAutopilotConsent(writeCtx, first); err != nil {
		t.Fatalf("another session's row lock blocked raw consent binding: %v", err)
	}
	var boundID string
	var observedAt time.Time
	if err := f.pool.QueryRow(ctx, `SELECT machine_id,last_observed_at FROM autopilot_reward_consents WHERE session_id=$1`, first.SessionID).Scan(&boundID, &observedAt); err != nil {
		t.Fatal(err)
	}
	if boundID != machineID || !observedAt.Equal(first.At) {
		t.Fatalf("current session did not bind and commit: machine=%q observed=%v", boundID, observedAt)
	}
	var otherUnbound bool
	if err := f.pool.QueryRow(ctx, `SELECT machine_id IS NULL FROM autopilot_reward_consents WHERE session_id=$1`, second.SessionID).Scan(&otherUnbound); err != nil || !otherUnbound {
		t.Fatalf("raw journal bound another session: unbound=%v err=%v", otherUnbound, err)
	}
}

func TestAutopilotConsentJournalRejectsUnboundAncestorOwner(t *testing.T) {
	f := newAutopilotRewardsFixture(t)
	ctx := t.Context()
	first := f.firstSeen.Add(8*24*time.Hour + 12*time.Hour)
	enrollment := f.enroll(t, "owner", "current", first, 70)
	ancestor, err := f.ObserveMachine(ctx, store.MachineObservation{SessionID: "historical", AccountID: "owner", SEKey: "historical-se", At: f.firstSeen})
	if err != nil || ancestor.ID == enrollment.MachineID {
		t.Fatalf("independent historical machine: %+v %v", ancestor, err)
	}
	// Retain an ancestral session mapping with inconsistent, unbound ownership
	// evidence. Only the consent-to-session join can discover its captured owner.
	if _, err := f.pool.Exec(ctx, `UPDATE darkbloom_machines SET merged_into=$1 WHERE id=$2`, enrollment.MachineID, ancestor.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := f.pool.Exec(ctx, `INSERT INTO autopilot_reward_consents
	 (machine_id,at,last_observed_at,account_id,session_id,opted_in,supported,qualified,chip,memory_gb)
	 VALUES(NULL,$1,$1,'other-owner','historical',true,true,true,'',0)`, first); err != nil {
		t.Fatal(err)
	}
	if _, err := f.SetAutopilotRewardPoolCap(ctx, 100); err != nil {
		t.Fatal(err)
	}
	before := queryLines(t, f.pool, autopilotFinancialSnapshotSQL)
	if receipt, err := f.SettleAutopilotRewardDay(ctx, enrollment.MachineID, enrollment.NextDay); !errors.Is(err, earningsfloor.ErrIdentity) {
		t.Fatalf("unbound ancestral consent owner was ignored: %+v %v", receipt, err)
	}
	assertSameLines(t, "before conflicting ownership", before, "after refused settlement", queryLines(t, f.pool, autopilotFinancialSnapshotSQL))
}
