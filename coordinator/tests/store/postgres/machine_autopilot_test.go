package postgres_test

import (
	"errors"
	"slices"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	production "github.com/eigeninference/d-inference/coordinator/store/postgres"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestMachineAutopilotPersistsAcrossNewStoreConnections(t *testing.T) {
	ctx := t.Context()
	databaseURL := newThrowawayTestDatabase(t)
	first, err := production.NewPostgres(ctx, store.Config{DatabaseURL: databaseURL})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(first.Close)
	observation := store.MachineObservation{SessionID: "before-restart", AccountID: "owner", SEKey: "stable-se", At: time.Now().UTC()}
	identity, err := first.ObserveMachine(ctx, observation)
	if err != nil {
		t.Fatal(err)
	}
	want := store.MachineAutopilotSetting{MachineID: identity.ID, DesiredMode: store.MachineAutopilotLive, Revision: 3}
	for _, mode := range []store.MachineAutopilotMode{store.MachineAutopilotLive, store.MachineAutopilotShadow, store.MachineAutopilotLive} {
		if _, err := first.SetMachineAutopilotDesiredMode(ctx, identity.ID, mode); err != nil {
			t.Fatal(err)
		}
	}
	first.Close()

	restarted, err := production.NewPostgres(ctx, store.Config{DatabaseURL: databaseURL})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(restarted.Close)
	if rows, err := restarted.LiveMachineAutopilotSettings(ctx); err != nil || !slices.Equal(rows, []store.MachineAutopilotSetting{want}) {
		t.Fatalf("new connection lost live policy: %+v %v", rows, err)
	}
	observation.SessionID, observation.At = "after-restart", observation.At.Add(time.Minute)
	if got, err := restarted.ObserveMachine(ctx, observation); err != nil || got.ID != identity.ID {
		t.Fatalf("restart reconnect lost identity: %+v %v", got, err)
	}
	if got, err := restarted.SetMachineAutopilotDesiredMode(ctx, identity.ID, store.MachineAutopilotLive); err != nil || got != want {
		t.Fatalf("restart changed idempotent revision: %+v %v", got, err)
	}
	if got, err := restarted.SetMachineAutopilotDesiredMode(ctx, identity.ID, store.MachineAutopilotShadow); err != nil || got.Revision != 4 {
		t.Fatalf("restart lost revision history: %+v %v", got, err)
	}
	if rows, err := restarted.LiveMachineAutopilotSettings(ctx); err != nil || len(rows) != 0 {
		t.Fatalf("demoted machine remained live: %+v %v", rows, err)
	}
}

func TestMachineAutopilotDatabaseConstraints(t *testing.T) {
	ctx := t.Context()
	s := testPostgresStore(t)
	identity, err := s.ObserveMachine(ctx, store.MachineObservation{SessionID: "constraints", At: time.Now().UTC()})
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name, column string
		value        any
		code         string
		constraint   string
	}{
		{"empty_mode", "autopilot_desired_mode", "", "23514", "darkbloom_machines_autopilot_desired_mode_check"},
		{"uppercase_mode", "autopilot_desired_mode", "LIVE", "23514", "darkbloom_machines_autopilot_desired_mode_check"},
		{"padded_mode", "autopilot_desired_mode", "shadow ", "23514", "darkbloom_machines_autopilot_desired_mode_check"},
		{"unknown_mode", "autopilot_desired_mode", "disabled", "23514", "darkbloom_machines_autopilot_desired_mode_check"},
		{"null_mode", "autopilot_desired_mode", nil, "23502", ""},
		{"negative_revision", "autopilot_revision", int64(-1), "23514", "darkbloom_machines_autopilot_revision_check"},
		{"null_revision", "autopilot_revision", nil, "23502", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := s.pool.Exec(ctx, "UPDATE darkbloom_machines SET "+tc.column+"=$2 WHERE id=$1", identity.ID, tc.value)
			var pgErr *pgconn.PgError
			if !errors.As(err, &pgErr) || pgErr.Code != tc.code || pgErr.ConstraintName != tc.constraint {
				t.Fatalf("invalid SQL update: %v, want %s %s", err, tc.code, tc.constraint)
			}
		})
	}
	want := []store.MachineAutopilotSetting{{MachineID: identity.ID, DesiredMode: store.MachineAutopilotShadow}}
	if rows, err := s.ListMachineAutopilotSettings(ctx, "", 100); err != nil || !slices.Equal(rows, want) {
		t.Fatalf("failed SQL writes changed policy: %+v %v", rows, err)
	}
}

func TestMachineAutopilotPropagatesDatabaseErrors(t *testing.T) {
	ctx := t.Context()
	s := testPostgresStore(t)
	identity, err := s.ObserveMachine(ctx, store.MachineObservation{SessionID: "db-errors", At: time.Now().UTC()})
	if err != nil {
		t.Fatal(err)
	}
	cfg := s.pool.Config()
	cfg.ConnConfig.RuntimeParams["default_transaction_read_only"] = "on"
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	readOnly := production.NewPostgresWithPool(pool)
	t.Cleanup(readOnly.Close)
	_, err = readOnly.SetMachineAutopilotDesiredMode(ctx, identity.ID, store.MachineAutopilotLive)
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) || pgErr.Code != "25006" {
		t.Fatalf("read-only setter error lost: %v", err)
	}
	want := []store.MachineAutopilotSetting{{MachineID: identity.ID, DesiredMode: store.MachineAutopilotShadow}}
	if rows, err := readOnly.ListMachineAutopilotSettings(ctx, "", 100); err != nil || !slices.Equal(rows, want) {
		t.Fatalf("failed setter changed policy: %+v %v", rows, err)
	}
	readOnly.Close()
	if rows, err := readOnly.ListMachineAutopilotSettings(ctx, "", 100); err == nil || len(rows) != 0 {
		t.Fatalf("closed pool list reported success: %+v %v", rows, err)
	}
	if rows, err := readOnly.LiveMachineAutopilotSettings(ctx); err == nil || len(rows) != 0 {
		t.Fatalf("closed pool live list reported success: %+v %v", rows, err)
	}
	if _, err := readOnly.SetMachineAutopilotDesiredMode(ctx, identity.ID, store.MachineAutopilotLive); err == nil || errors.Is(err, store.ErrNotFound) {
		t.Fatalf("closed pool setter hid database error: %v", err)
	}
}
