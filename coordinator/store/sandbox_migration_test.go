package store

import (
	"context"
	"testing"
	"time"
)

func TestSandboxMigrationRepairsConcurrentActiveCommands(t *testing.T) {
	backend := testPostgresStore(t)
	ctx := context.Background()
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
			($1, $3, $4, $1, 1, $5, '["/usr/bin/true"]', 900, 'running', $6, $6),
			($2, $3, $4, $2, 1, $5, '["/usr/bin/true"]', 900, 'pending', $7, $7)`,
		"50000000-0000-0000-0000-000000000305",
		"60000000-0000-0000-0000-000000000306",
		stored.ID,
		stored.AccountID,
		stored.FencingToken,
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

	var active, lost int
	if err := tx.QueryRow(
		ctx,
		`SELECT
			COUNT(*) FILTER (WHERE state IN ('pending', 'accepted', 'running')),
			COUNT(*) FILTER (
				WHERE state = 'lost'
				  AND error_code = 'upgrade_concurrent_command'
				  AND completed_at IS NOT NULL
			)
		 FROM sandbox_commands
		 WHERE sandbox_id = $1`,
		stored.ID,
	).Scan(&active, &lost); err != nil {
		t.Fatalf("inspect repaired commands: %v", err)
	}
	if active != 1 || lost != 1 {
		t.Fatalf("repaired command counts active=%d lost=%d, want 1/1", active, lost)
	}
}
