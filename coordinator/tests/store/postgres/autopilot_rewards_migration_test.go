package postgres_test

import (
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
	"github.com/jackc/pgx/v5/pgconn"
)

func TestAutopilotRewardsMigrationEquivalentAndReplaySafe(t *testing.T) {
	ctx := t.Context()
	dumpURL := newThrowawayTestDatabase(t)
	dumpPool := openTestPool(t, dumpURL)
	loadSchemaFile(t, dumpPool)
	wantSchema := schemaSnapshot(t, dumpPool)

	for _, source := range []string{"empty", "legacy", "current"} {
		t.Run(source, func(t *testing.T) {
			databaseURL := newThrowawayTestDatabase(t)
			pool := openTestPool(t, databaseURL)
			switch source {
			case "legacy":
				loadSchema(t, pool, legacySchemaFile)
			case "current":
				loadSchemaFile(t, pool)
			}
			before := time.Now().Add(-time.Second)
			s, err := openPostgresFixture(ctx, store.Config{DatabaseURL: databaseURL})
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(s.Close)
			assertSameLines(t, "schema dump", wantSchema, source+" migrated", schemaSnapshot(t, pool))
			initial, err := s.AutopilotRewardPool(ctx)
			if err != nil || initial.CapMicroUSD != 0 || initial.SpentMicroUSD != 0 || initial.TrackingStartedAt.Before(before) || initial.TrackingStartedAt.After(time.Now()) {
				t.Fatalf("initial pool: %+v %v", initial, err)
			}
			if _, err := s.SetAutopilotRewardPoolCap(ctx, 17); err != nil {
				t.Fatal(err)
			}
			if _, err := pool.Exec(ctx, `UPDATE autopilot_reward_pool SET spent_micro_usd=9 WHERE singleton`); err != nil {
				t.Fatal(err)
			}
			for _, step := range []string{"restart", "replay"} {
				if step == "restart" {
					if err := s.reopen(ctx); err != nil {
						t.Fatal(err)
					}
				} else {
					replayMigrations(t, s)
				}
				current, err := s.AutopilotRewardPool(ctx)
				if err != nil || current.CapMicroUSD != 17 || current.SpentMicroUSD != 9 || !current.TrackingStartedAt.Equal(initial.TrackingStartedAt) {
					t.Fatalf("%s reset reward accounting or tracking start: %+v %v", step, current, err)
				}
				assertSameLines(t, "schema dump", wantSchema, step, schemaSnapshot(t, pool))
			}
			var applied int
			if err := pool.QueryRow(ctx, `SELECT count(*) FROM goose_db_version WHERE version_id=31 AND is_applied`).Scan(&applied); err != nil || applied != 1 {
				t.Fatalf("migration 31 application count: %d %v", applied, err)
			}
			var obsolete bool
			if err := pool.QueryRow(ctx, `SELECT to_regclass('autopilot_floor_program') IS NOT NULL
			 OR to_regclass('autopilot_floor_receipts') IS NOT NULL
			 OR EXISTS(SELECT 1 FROM information_schema.columns WHERE table_name='provider_earnings' AND column_name='paid_work_micro_usd')`).Scan(&obsolete); err != nil || obsolete {
				t.Fatalf("superseded earnings-floor schema exists: %v %v", obsolete, err)
			}
		})
	}
}

func TestAutopilotRewardsMigrationConstrainsBaselineSource(t *testing.T) {
	f := newAutopilotRewardsFixture(t)
	ctx := t.Context()
	first := f.firstSeen.Add(8*24*time.Hour + 12*time.Hour)
	tracked := f.enroll(t, "owner", "tracked", first, 70)
	if tracked.BaselineSource != earningsfloor.TrackedBaseline {
		t.Fatalf("automatic baseline has no explicit source: %+v", tracked)
	}
	if _, err := f.ObserveMachine(ctx, store.MachineObservation{SessionID: "old", AccountID: "owner", SEKey: "old", At: f.firstSeen.Add(-48 * time.Hour)}); err != nil {
		t.Fatal(err)
	}
	unknown, err := f.ObserveAutopilotConsent(ctx, earningsfloor.Consent{SessionID: "old", AccountID: "owner", Supported: true, Qualified: true, OptedIn: true, At: first})
	if err != nil || unknown.BaselineKnown || unknown.BaselineSource != "" {
		t.Fatalf("unknown baseline default source: %+v %v", unknown, err)
	}
	for _, invalid := range []struct{ machineID, source string }{
		{tracked.MachineID, ""}, {tracked.MachineID, "manual"}, {tracked.MachineID, "TRACKED"},
		{unknown.MachineID, earningsfloor.TrackedBaseline}, {unknown.MachineID, earningsfloor.VerifiedBaseline},
	} {
		_, err := f.pool.Exec(ctx, `UPDATE autopilot_reward_enrollments SET baseline_source=$2 WHERE machine_id=$1`, invalid.machineID, invalid.source)
		var pgErr *pgconn.PgError
		if !errors.As(err, &pgErr) || pgErr.Code != "23514" || pgErr.ConstraintName != "autopilot_reward_enrollments_source_check" {
			t.Fatalf("invalid baseline source %q accepted or wrong failure: %v", invalid.source, err)
		}
	}
	verified, err := f.RestoreAutopilotBaseline(ctx, earningsfloor.Baseline{MachineID: unknown.MachineID, FirstOptInAt: first, SevenDayEarningsMicroUSD: 70, Evidence: "verified original consent and payouts"})
	if err != nil || verified.BaselineSource != earningsfloor.VerifiedBaseline {
		t.Fatalf("valid verified history source rejected: %+v %v", verified, err)
	}
	f.reopenRewards(t)
	rows, err := f.AutopilotRewardEnrollments(ctx, "", 100)
	if err != nil || len(rows) != 2 {
		t.Fatalf("source persistence: %+v %v", rows, err)
	}
	for _, row := range rows {
		want := earningsfloor.TrackedBaseline
		if row.MachineID == unknown.MachineID {
			want = earningsfloor.VerifiedBaseline
		}
		if row.BaselineSource != want {
			t.Fatalf("reopen changed baseline provenance: %+v want %s", row, want)
		}
	}
}
