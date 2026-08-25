package store

import (
	"context"
	"testing"
	"time"
)

func TestSandboxMigrationRepairsConcurrentActiveCommands(t *testing.T) {
	backend := testPostgresStore(t)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	now := time.Date(2026, 8, 25, 9, 0, 0, 0, time.UTC)
	sandbox, prepare := sandboxFencingFixture(
		"10000000-0000-0000-0000-000000000301",
		"20000000-0000-0000-0000-000000000302",
		"30000000-0000-0000-0000-000000000303",
		uniqueID("migration-concurrent-commands"),
		"40000000-0000-0000-0000-000000000304",
		1,
		now,
	)
	stored, _, _, err := backend.CreateSandbox(
		ctx,
		sandbox,
		prepare,
		SandboxAllocationLimits{
			MaximumActive:     2,
			MaximumPerAccount: 2,
			MaximumPerHost:    2,
		},
	)
	if err != nil {
		t.Fatalf("create sandbox: %v", err)
	}

	tx, err := backend.pool.Begin(ctx)
	if err != nil {
		t.Fatalf("begin migration fixture: %v", err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	if _, err := tx.Exec(
		ctx,
		`DROP INDEX idx_sandbox_commands_one_active`,
	); err != nil {
		t.Fatalf("drop active-command index: %v", err)
	}
	if _, err := tx.Exec(
		ctx,
		`INSERT INTO sandbox_commands (
			id, sandbox_id, account_id, idempotency_key, generation,
			fencing_token, arguments, timeout_seconds, state,
			created_at, updated_at
		) VALUES
			($1, $3, $4, $6, 1, $5, '["/usr/bin/true"]', 900, 'running', $8, $8),
			($2, $3, $4, $7, 1, $5, '["/usr/bin/true"]', 900, 'pending', $9, $9)`,
		"50000000-0000-0000-0000-000000000305",
		"60000000-0000-0000-0000-000000000306",
		stored.ID,
		stored.AccountID,
		stored.FencingToken,
		"50000000-0000-0000-0000-000000000305",
		"60000000-0000-0000-0000-000000000306",
		now.Add(time.Second),
		now.Add(2*time.Second),
	); err != nil {
		t.Fatalf("seed concurrent active commands: %v", err)
	}
	if _, err := tx.Exec(
		ctx,
		sandboxActiveCommandConstraintMigration,
	); err != nil {
		t.Fatalf("repair and constrain concurrent active commands: %v", err)
	}

	var active, quarantined int
	if err := tx.QueryRow(
		ctx,
		`SELECT
			COUNT(*) FILTER (WHERE state IN ('pending', 'accepted', 'running')),
			COUNT(*) FILTER (
				WHERE state = 'lost'
				  AND error_code = 'upgrade_concurrent_command'
				  AND cancellation_pending
				  AND completed_at IS NOT NULL
			)
		 FROM sandbox_commands
		 WHERE sandbox_id = $1`,
		stored.ID,
	).Scan(&active, &quarantined); err != nil {
		t.Fatalf("inspect repaired commands: %v", err)
	}
	if active != 1 || quarantined != 1 {
		t.Fatalf(
			"repaired command counts active=%d quarantined=%d, want 1/1",
			active,
			quarantined,
		)
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatalf("commit repaired command fixture: %v", err)
	}

	if _, err := backend.pool.Exec(
		ctx,
		`DROP INDEX idx_sandbox_commands_one_active`,
	); err != nil {
		t.Fatalf("drop active-command index for concurrent migration: %v", err)
	}
	if _, err := backend.pool.Exec(
		ctx,
		`INSERT INTO sandbox_commands (
			id, sandbox_id, account_id, idempotency_key, generation,
			fencing_token, arguments, timeout_seconds, state,
			created_at, updated_at
		) VALUES (
			$1, $2, $3, $4, 1, $5, '["/usr/bin/true"]', 900,
			'running', $6, $6
		)`,
		"70000000-0000-0000-0000-000000000307",
		stored.ID,
		stored.AccountID,
		"70000000-0000-0000-0000-000000000307",
		stored.FencingToken,
		now.Add(3*time.Second),
	); err != nil {
		t.Fatalf("seed command for concurrent migration: %v", err)
	}

	start := make(chan struct{})
	results := make(chan error, 2)
	for range 2 {
		go func() {
			<-start
			results <- backend.executeSchemaMigrations(
				ctx,
				[]string{sandboxActiveCommandConstraintMigration},
			)
		}()
	}
	close(start)
	for range 2 {
		if err := <-results; err != nil {
			t.Fatalf("concurrent active-command migration: %v", err)
		}
	}

	if err := backend.pool.QueryRow(
		ctx,
		`SELECT
			COUNT(*) FILTER (WHERE state IN ('pending', 'accepted', 'running')),
			COUNT(*) FILTER (
				WHERE state = 'lost'
				  AND error_code = 'upgrade_concurrent_command'
				  AND cancellation_pending
			)
		 FROM sandbox_commands
		 WHERE sandbox_id = $1`,
		stored.ID,
	).Scan(&active, &quarantined); err != nil {
		t.Fatalf("inspect concurrently repaired commands: %v", err)
	}
	if active != 1 || quarantined != 2 {
		t.Fatalf(
			"concurrent repair counts active=%d quarantined=%d, want 1/2",
			active,
			quarantined,
		)
	}

	pending, err := backend.ListPendingSandboxCommandCancellations(
		ctx,
		[]string{stored.HostID},
		1,
	)
	if err != nil {
		t.Fatalf("list first pending cancellation: %v", err)
	}
	if len(pending) != 1 {
		t.Fatalf("first pending cancellation count = %d, want 1", len(pending))
	}
	firstCommandID := pending[0].Command.ID
	if err := backend.RecordSandboxCommandCancellationDispatch(
		ctx,
		firstCommandID,
		now.Add(4*time.Second),
		"",
	); err != nil {
		t.Fatalf("record first cancellation dispatch: %v", err)
	}
	pending, err = backend.ListPendingSandboxCommandCancellations(
		ctx,
		[]string{stored.HostID},
		1,
	)
	if err != nil {
		t.Fatalf("list rotated pending cancellation: %v", err)
	}
	if len(pending) != 1 {
		t.Fatalf("rotated pending cancellation count = %d, want 1", len(pending))
	}
	if pending[0].Command.ID == firstCommandID {
		t.Fatalf(
			"bounded cancellation query did not rotate after dispatching %s",
			firstCommandID,
		)
	}
}
