package postgres_test

import (
	"context"
	"errors"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	production "github.com/eigeninference/d-inference/coordinator/store/postgres"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgconn"
)

func TestMachineAutopilotMigrationDefaultsLegacyInventory(t *testing.T) {
	ctx := t.Context()
	databaseURL := newThrowawayTestDatabase(t)
	pool := openTestPool(t, databaseURL)
	loadSchema(t, pool, legacySchemaFile)
	winner, loser := uuid.NewString(), uuid.NewString()
	if _, err := pool.Exec(ctx, `INSERT INTO darkbloom_machines(id,assurance,merged_into,first_seen,last_seen) VALUES
	 ($1,'hardware_verified',NULL,'2026-01-01','2026-10-01'),
	 ($2,'key_bound',$1,'2026-02-01','2026-09-01')`, winner, loser); err != nil {
		t.Fatal(err)
	}
	const identityRows = `SELECT json_build_array(id,assurance,merged_into,first_seen,last_seen)::text FROM darkbloom_machines ORDER BY id`
	before := queryLines(t, pool, identityRows)
	s, err := production.NewPostgres(ctx, store.Config{DatabaseURL: databaseURL})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	assertSameLines(t, "legacy inventory", before, "migrated inventory", queryLines(t, pool, identityRows))
	want := []store.MachineAutopilotSetting{{MachineID: winner, DesiredMode: store.MachineAutopilotShadow}}
	if rows, err := s.ListMachineAutopilotSettings(ctx, "", 100); err != nil || !slices.Equal(rows, want) {
		t.Fatalf("legacy default settings: %+v %v", rows, err)
	}
	if rows, err := s.LiveMachineAutopilotSettings(ctx); err != nil || len(rows) != 0 {
		t.Fatalf("migration opted legacy machines in: %+v %v", rows, err)
	}
	var allShadow bool
	if err := pool.QueryRow(ctx, `SELECT bool_and(autopilot_desired_mode='shadow' AND autopilot_revision=0) FROM darkbloom_machines`).Scan(&allShadow); err != nil || !allShadow {
		t.Fatalf("legacy rows did not all default to shadow revision zero: %v %v", allShadow, err)
	}
	if _, err := s.SetMachineAutopilotDesiredMode(ctx, loser, store.MachineAutopilotLive); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("migrated merged ID accepted: %v", err)
	}
}

func TestMachineAutopilotMigrationAdoptionAndReplayPreservePolicy(t *testing.T) {
	for _, removeChecks := range []bool{false, true} {
		name := "current_schema"
		if removeChecks {
			name = "columns_without_checks"
		}
		t.Run(name, func(t *testing.T) {
			ctx := t.Context()
			databaseURL := newThrowawayTestDatabase(t)
			pool := openTestPool(t, databaseURL)
			loadSchemaFile(t, pool)
			wantSchema := schemaSnapshot(t, pool)
			if removeChecks {
				if _, err := pool.Exec(ctx, `ALTER TABLE darkbloom_machines
				 DROP CONSTRAINT darkbloom_machines_autopilot_desired_mode_check,
				 DROP CONSTRAINT darkbloom_machines_autopilot_revision_check`); err != nil {
					t.Fatal(err)
				}
			}
			live, shadow, retired := uuid.NewString(), uuid.NewString(), uuid.NewString()
			if _, err := pool.Exec(ctx, `INSERT INTO darkbloom_machines(id,assurance,merged_into,first_seen,last_seen,autopilot_desired_mode,autopilot_revision) VALUES
			 ($1,'key_bound',NULL,'2026-01-01','2026-10-01','live',7),
			 ($2,'key_bound',NULL,'2026-02-01','2026-09-01','shadow',4),
			 ($3,'key_bound',$2,'2026-03-01','2026-08-01','live',11)`, live, shadow, retired); err != nil {
				t.Fatal(err)
			}
			const policyRows = `SELECT row_to_json(m)::text FROM darkbloom_machines m ORDER BY id`
			before := queryLines(t, pool, policyRows)
			s, err := openPostgresFixture(ctx, store.Config{DatabaseURL: databaseURL})
			if err != nil {
				t.Fatalf("adopt preexisting Autopilot settings: %v", err)
			}
			t.Cleanup(s.Close)
			for _, step := range []string{"adoption", "restart", "replay"} {
				switch step {
				case "restart":
					if err := s.reopen(ctx); err != nil {
						t.Fatal(err)
					}
				case "replay":
					replayMigrations(t, s)
				}
				assertSameLines(t, "existing machine policies", before, step, queryLines(t, pool, policyRows))
				assertSameLines(t, "current schema", wantSchema, step, schemaSnapshot(t, pool))
				versions := queryLines(t, pool, `SELECT version_id::text FROM goose_db_version WHERE version_id IN (29,30) AND is_applied ORDER BY version_id`)
				if strings.Join(versions, " ") != "29 30" {
					t.Fatalf("%s migration versions: %v, want 29 and 30 once each", step, versions)
				}
			}
			wantLive := store.MachineAutopilotSetting{MachineID: live, DesiredMode: store.MachineAutopilotLive, Revision: 7}
			if rows, err := s.LiveMachineAutopilotSettings(ctx); err != nil || !slices.Equal(rows, []store.MachineAutopilotSetting{wantLive}) {
				t.Fatalf("adoption/replay changed live cohort: %+v %v", rows, err)
			}
			want := []store.MachineAutopilotSetting{wantLive, {MachineID: shadow, DesiredMode: store.MachineAutopilotShadow, Revision: 4}}
			slices.SortFunc(want, func(a, b store.MachineAutopilotSetting) int { return strings.Compare(a.MachineID, b.MachineID) })
			if rows, err := s.ListMachineAutopilotSettings(ctx, "", 100); err != nil || !slices.Equal(rows, want) {
				t.Fatalf("adoption/replay changed settings: %+v %v", rows, err)
			}
		})
	}
}

func TestMachineAutopilotMigrationValidatesInSeparateTransaction(t *testing.T) {
	ctx := t.Context()
	databaseURL := newThrowawayTestDatabase(t)
	pool := openTestPool(t, databaseURL)
	loadSchemaFile(t, pool)
	if _, err := pool.Exec(ctx, `ALTER TABLE darkbloom_machines
	 DROP CONSTRAINT darkbloom_machines_autopilot_desired_mode_check,
	 DROP CONSTRAINT darkbloom_machines_autopilot_revision_check`); err != nil {
		t.Fatal(err)
	}
	badMode, badRevision := uuid.NewString(), uuid.NewString()
	if _, err := pool.Exec(ctx, `INSERT INTO darkbloom_machines(id,assurance,first_seen,last_seen,autopilot_desired_mode,autopilot_revision) VALUES
	 ($1,'key_bound','2026-01-01','2026-10-01','invalid',0),
	 ($2,'key_bound','2026-01-01','2026-10-01','shadow',-1)`, badMode, badRevision); err != nil {
		t.Fatal(err)
	}
	assertValidationFailure := func(constraint string) {
		t.Helper()
		s, err := production.NewPostgres(ctx, store.Config{DatabaseURL: databaseURL})
		if s != nil {
			s.Close()
		}
		var pgErr *pgconn.PgError
		if !errors.As(err, &pgErr) || pgErr.Code != "23514" || pgErr.ConstraintName != constraint {
			t.Fatalf("validate %s: %v, want check violation", constraint, err)
		}
		versions := queryLines(t, pool, `SELECT version_id::text FROM goose_db_version WHERE version_id IN (29,30) AND is_applied ORDER BY version_id`)
		if strings.Join(versions, " ") != "29" {
			t.Fatalf("constraint creation must commit separately from failed validation: %v", versions)
		}
		var unvalidated int
		if err := pool.QueryRow(ctx, `SELECT count(*) FROM pg_constraint WHERE conrelid='darkbloom_machines'::regclass
		 AND conname IN ('darkbloom_machines_autopilot_desired_mode_check','darkbloom_machines_autopilot_revision_check') AND NOT convalidated`).Scan(&unvalidated); err != nil || unvalidated != 2 {
			t.Fatalf("checks were not retained as NOT VALID: %d %v", unvalidated, err)
		}
	}
	assertValidationFailure("darkbloom_machines_autopilot_desired_mode_check")
	if _, err := pool.Exec(ctx, `UPDATE darkbloom_machines SET autopilot_desired_mode='shadow' WHERE id=$1`, badMode); err != nil {
		t.Fatal(err)
	}
	assertValidationFailure("darkbloom_machines_autopilot_revision_check")
	if _, err := pool.Exec(ctx, `UPDATE darkbloom_machines SET autopilot_revision=0 WHERE id=$1`, badRevision); err != nil {
		t.Fatal(err)
	}

	// Keep an ordinary writer open: validation must not reacquire version 29's
	// ACCESS EXCLUSIVE lock while scanning the preexisting rows.
	holder, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer holder.Rollback(context.Background())
	if _, err := holder.Exec(ctx, `INSERT INTO darkbloom_machines(id,assurance,first_seen,last_seen) VALUES($1,'provisional',now(),now())`, uuid.NewString()); err != nil {
		t.Fatal(err)
	}
	validationCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	s, err := production.NewPostgres(validationCtx, store.Config{DatabaseURL: databaseURL})
	if err != nil {
		t.Fatalf("validation blocked ordinary writer or failed after repair: %v", err)
	}
	t.Cleanup(s.Close)
	if err := holder.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	var validated int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM pg_constraint WHERE conrelid='darkbloom_machines'::regclass
	 AND conname IN ('darkbloom_machines_autopilot_desired_mode_check','darkbloom_machines_autopilot_revision_check') AND convalidated`).Scan(&validated); err != nil || validated != 2 {
		t.Fatalf("checks were not validated: %d %v", validated, err)
	}
	versions := queryLines(t, pool, `SELECT version_id::text FROM goose_db_version WHERE version_id IN (29,30) AND is_applied ORDER BY version_id`)
	if strings.Join(versions, " ") != "29 30" {
		t.Fatalf("migration retry did not apply both versions once: %v", versions)
	}
}
