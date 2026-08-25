package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

const sandboxSelectColumns = `
	id::text, account_id, created_by_key_id, host_id::text,
	generation, fencing_token, base_image_id, cpu_count, memory_bytes,
	workspace_bytes, command_timeout_seconds, gpu, state, termination_requested,
	lease_expires_at, error_code, created_at, updated_at`

const sandboxOperationSelectColumns = `
	id::text, sandbox_id::text, account_id, kind, state, generation,
	fencing_token, previous_sandbox_state, delete_after_stop,
	requested_lease_expires_at, error_code, created_at, updated_at`

const sandboxCommandSelectColumns = `
	id::text, sandbox_id::text, account_id, idempotency_key, generation,
	fencing_token, arguments, environment, working_directory, timeout_seconds,
	state, exit_code, stdout, stderr, output_truncated, error_code, created_at,
	started_at, completed_at, updated_at`

func (s *PostgresStore) CreateSandbox(
	ctx context.Context,
	sandbox *SandboxRecord,
	operation *SandboxOperation,
) error {
	if err := validateSandboxCreate(sandbox, operation); err != nil {
		return err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin sandbox create: %w", err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	if _, err := tx.Exec(
		ctx,
		`INSERT INTO sandboxes (
			id, account_id, created_by_key_id, host_id, generation,
			fencing_token, base_image_id, cpu_count, memory_bytes,
			workspace_bytes, command_timeout_seconds, gpu, state,
			termination_requested, lease_expires_at, error_code, created_at,
			updated_at
		) VALUES (
			$1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13,
			$14, $15, $16, $17, $18
		)`,
		sandbox.ID,
		sandbox.AccountID,
		sandbox.CreatedByKeyID,
		sandbox.HostID,
		sandbox.Generation,
		sandbox.FencingToken,
		sandbox.BaseImageID,
		sandbox.CPUCount,
		sandbox.MemoryBytes,
		sandbox.WorkspaceBytes,
		sandbox.CommandTimeoutSeconds,
		sandbox.GPU,
		sandbox.State,
		sandbox.TerminationRequested,
		sandbox.LeaseExpiresAt,
		sandbox.ErrorCode,
		sandbox.CreatedAt,
		sandbox.UpdatedAt,
	); err != nil {
		return sandboxPostgresError("insert sandbox", err)
	}
	if err := insertSandboxOperation(ctx, tx, operation); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit sandbox create: %w", err)
	}
	return nil
}

func (s *PostgresStore) GetSandbox(
	ctx context.Context,
	accountID string,
	sandboxID string,
) (*SandboxRecord, error) {
	record, err := scanSandboxRecord(s.pool.QueryRow(
		ctx,
		`SELECT `+sandboxSelectColumns+`
		 FROM sandboxes
		 WHERE id = $1 AND account_id = $2`,
		sandboxID,
		accountID,
	))
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, fmt.Errorf("sandbox %s: %w", sandboxID, ErrNotFound)
	}
	return record, err
}

func (s *PostgresStore) GetSandboxByID(
	ctx context.Context,
	sandboxID string,
) (*SandboxRecord, error) {
	record, err := scanSandboxRecord(s.pool.QueryRow(
		ctx,
		`SELECT `+sandboxSelectColumns+`
		 FROM sandboxes
		 WHERE id = $1`,
		sandboxID,
	))
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, fmt.Errorf("sandbox %s: %w", sandboxID, ErrNotFound)
	}
	return record, err
}

func (s *PostgresStore) ListSandboxes(
	ctx context.Context,
	accountID string,
	limit int,
) ([]SandboxRecord, error) {
	rows, err := s.pool.Query(
		ctx,
		`SELECT `+sandboxSelectColumns+`
		 FROM sandboxes
		 WHERE account_id = $1
		 ORDER BY created_at DESC
		 LIMIT $2`,
		accountID,
		sandboxListLimit(limit),
	)
	if err != nil {
		return nil, fmt.Errorf("list sandboxes: %w", err)
	}
	defer rows.Close()
	result := make([]SandboxRecord, 0)
	for rows.Next() {
		record, err := scanSandboxRecord(rows)
		if err != nil {
			return nil, err
		}
		result = append(result, *record)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("list sandboxes: %w", err)
	}
	return result, nil
}

func (s *PostgresStore) ListActiveSandboxesByHost(
	ctx context.Context,
	hostID string,
) ([]SandboxRecord, error) {
	rows, err := s.pool.Query(
		ctx,
		`SELECT `+sandboxSelectColumns+`
		 FROM sandboxes
		 WHERE host_id = $1 AND state NOT IN ($2, $3)
		 ORDER BY created_at`,
		hostID,
		SandboxStateDeleted,
		SandboxStateFailed,
	)
	if err != nil {
		return nil, fmt.Errorf("list active host sandboxes: %w", err)
	}
	defer rows.Close()
	result := make([]SandboxRecord, 0)
	for rows.Next() {
		record, err := scanSandboxRecord(rows)
		if err != nil {
			return nil, err
		}
		result = append(result, *record)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("list active host sandboxes: %w", err)
	}
	return result, nil
}

func (s *PostgresStore) BeginSandboxOperation(
	ctx context.Context,
	operation *SandboxOperation,
	targetState string,
) (*SandboxRecord, error) {
	if err := validateSandboxOperationStart(operation, targetState); err != nil {
		return nil, err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, fmt.Errorf("begin sandbox operation: %w", err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	sandbox, err := scanSandboxRecord(tx.QueryRow(
		ctx,
		`SELECT `+sandboxSelectColumns+`
		 FROM sandboxes
		 WHERE id = $1
		 FOR UPDATE`,
		operation.SandboxID,
	))
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && sandbox.AccountID != operation.AccountID) {
		return nil, fmt.Errorf(
			"sandbox %s: %w",
			operation.SandboxID,
			ErrNotFound,
		)
	}
	if err != nil {
		return nil, err
	}
	if sandbox.Generation != operation.Generation ||
		sandbox.FencingToken != operation.FencingToken ||
		sandbox.State != operation.PreviousSandboxState ||
		sandbox.Terminal() {
		return nil, ErrSandboxConflict
	}
	if err := insertSandboxOperation(ctx, tx, operation); err != nil {
		return nil, err
	}
	sandbox.State = targetState
	if operation.Kind == SandboxOperationKindDelete ||
		operation.DeleteAfterStop {
		sandbox.TerminationRequested = true
	}
	sandbox.ErrorCode = ""
	sandbox.UpdatedAt = operation.UpdatedAt
	if _, err := tx.Exec(
		ctx,
		`UPDATE sandboxes
		 SET state = $2, termination_requested = $3, error_code = '',
		     updated_at = $4
		 WHERE id = $1`,
		sandbox.ID,
		sandbox.State,
		sandbox.TerminationRequested,
		sandbox.UpdatedAt,
	); err != nil {
		return nil, fmt.Errorf("update sandbox operation state: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, fmt.Errorf("commit sandbox operation: %w", err)
	}
	return sandbox, nil
}

func (s *PostgresStore) GetSandboxOperation(
	ctx context.Context,
	accountID string,
	operationID string,
) (*SandboxOperation, error) {
	operation, err := scanSandboxOperation(s.pool.QueryRow(
		ctx,
		`SELECT `+sandboxOperationSelectColumns+`
		 FROM sandbox_host_operations
		 WHERE id = $1 AND account_id = $2`,
		operationID,
		accountID,
	))
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, fmt.Errorf(
			"sandbox operation %s: %w",
			operationID,
			ErrNotFound,
		)
	}
	return operation, err
}

func (s *PostgresStore) ApplySandboxOperationUpdate(
	ctx context.Context,
	update SandboxOperationUpdate,
) (*SandboxRecord, *SandboxOperation, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, nil, fmt.Errorf("begin sandbox result: %w", err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	sandbox, err := scanSandboxRecord(tx.QueryRow(
		ctx,
		`SELECT `+sandboxSelectColumns+`
		 FROM sandboxes
		 WHERE id = $1
		 FOR UPDATE`,
		update.SandboxID,
	))
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil, ErrNotFound
	}
	if err != nil {
		return nil, nil, err
	}
	operation, err := scanSandboxOperation(tx.QueryRow(
		ctx,
		`SELECT `+sandboxOperationSelectColumns+`
		 FROM sandbox_host_operations
		 WHERE id = $1
		 FOR UPDATE`,
		update.OperationID,
	))
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil, ErrNotFound
	}
	if err != nil {
		return nil, nil, err
	}
	if err := applySandboxOperationTransition(
		sandbox,
		operation,
		update,
	); err != nil {
		return nil, nil, err
	}
	if _, err := tx.Exec(
		ctx,
		`UPDATE sandboxes
		 SET fencing_token = $2, state = $3, lease_expires_at = $4,
		     error_code = $5, updated_at = $6
		 WHERE id = $1`,
		sandbox.ID,
		sandbox.FencingToken,
		sandbox.State,
		sandbox.LeaseExpiresAt,
		sandbox.ErrorCode,
		sandbox.UpdatedAt,
	); err != nil {
		return nil, nil, fmt.Errorf("update sandbox result: %w", err)
	}
	if _, err := tx.Exec(
		ctx,
		`UPDATE sandbox_host_operations
		 SET state = $2, error_code = $3, updated_at = $4
		 WHERE id = $1`,
		operation.ID,
		operation.State,
		operation.ErrorCode,
		operation.UpdatedAt,
	); err != nil {
		return nil, nil, fmt.Errorf("update sandbox operation result: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, nil, fmt.Errorf("commit sandbox result: %w", err)
	}
	return sandbox, operation, nil
}

func (s *PostgresStore) CreateSandboxCommand(
	ctx context.Context,
	command *SandboxCommand,
) (*SandboxCommand, bool, error) {
	if err := validateSandboxCommandCreate(command); err != nil {
		return nil, false, err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, false, fmt.Errorf("begin sandbox command: %w", err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	existing, err := getSandboxCommandByIdempotency(
		ctx,
		tx,
		command.AccountID,
		command.SandboxID,
		command.IdempotencyKey,
	)
	if err == nil {
		return existing, false, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return nil, false, err
	}

	sandbox, err := scanSandboxRecord(tx.QueryRow(
		ctx,
		`SELECT `+sandboxSelectColumns+`
		 FROM sandboxes
		 WHERE id = $1
		 FOR UPDATE`,
		command.SandboxID,
	))
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && sandbox.AccountID != command.AccountID) {
		return nil, false, fmt.Errorf(
			"sandbox %s: %w",
			command.SandboxID,
			ErrNotFound,
		)
	}
	if err != nil {
		return nil, false, err
	}

	// Re-check after taking the sandbox lock. Another transaction may have
	// inserted the same idempotency key while this transaction was waiting.
	existing, err = getSandboxCommandByIdempotency(
		ctx,
		tx,
		command.AccountID,
		command.SandboxID,
		command.IdempotencyKey,
	)
	if err == nil {
		return existing, false, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return nil, false, err
	}
	if sandbox.State != SandboxStateReady ||
		sandbox.Generation != command.Generation ||
		sandbox.FencingToken != command.FencingToken {
		return nil, false, ErrSandboxConflict
	}
	arguments, environment, err := sandboxCommandJSON(command)
	if err != nil {
		return nil, false, fmt.Errorf("encode sandbox command: %w", err)
	}
	if _, err := tx.Exec(
		ctx,
		`INSERT INTO sandbox_commands (
			id, sandbox_id, account_id, idempotency_key, generation,
			fencing_token, arguments, environment, working_directory,
			timeout_seconds, state, exit_code, stdout, stderr,
			output_truncated, error_code, created_at, started_at,
			completed_at, updated_at
		) VALUES (
			$1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13,
			$14, $15, $16, $17, $18, $19, $20
		)`,
		command.ID,
		command.SandboxID,
		command.AccountID,
		command.IdempotencyKey,
		command.Generation,
		command.FencingToken,
		arguments,
		environment,
		command.WorkingDirectory,
		command.TimeoutSeconds,
		command.State,
		command.ExitCode,
		command.StandardOutput,
		command.StandardError,
		command.OutputTruncated,
		command.ErrorCode,
		command.CreatedAt,
		command.StartedAt,
		command.CompletedAt,
		command.UpdatedAt,
	); err != nil {
		return nil, false, sandboxPostgresError(
			"insert sandbox command",
			err,
		)
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, false, fmt.Errorf("commit sandbox command: %w", err)
	}
	return cloneSandboxCommand(command), true, nil
}

func (s *PostgresStore) GetSandboxCommand(
	ctx context.Context,
	accountID string,
	sandboxID string,
	commandID string,
) (*SandboxCommand, error) {
	command, err := scanSandboxCommand(s.pool.QueryRow(
		ctx,
		`SELECT `+sandboxCommandSelectColumns+`
		 FROM sandbox_commands
		 WHERE id = $1 AND sandbox_id = $2 AND account_id = $3`,
		commandID,
		sandboxID,
		accountID,
	))
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, fmt.Errorf(
			"sandbox command %s: %w",
			commandID,
			ErrNotFound,
		)
	}
	return command, err
}

func (s *PostgresStore) ApplySandboxCommandUpdate(
	ctx context.Context,
	update SandboxCommandUpdate,
) (*SandboxCommand, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, fmt.Errorf("begin sandbox command result: %w", err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	sandbox, err := scanSandboxRecord(tx.QueryRow(
		ctx,
		`SELECT `+sandboxSelectColumns+`
		 FROM sandboxes
		 WHERE id = $1
		 FOR UPDATE`,
		update.SandboxID,
	))
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	command, err := scanSandboxCommand(tx.QueryRow(
		ctx,
		`SELECT `+sandboxCommandSelectColumns+`
		 FROM sandbox_commands
		 WHERE id = $1
		 FOR UPDATE`,
		update.CommandID,
	))
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if sandbox.Generation != update.Generation ||
		sandbox.FencingToken != update.FencingToken {
		return nil, ErrSandboxConflict
	}
	if err := applySandboxCommandTransition(command, update); err != nil {
		return nil, err
	}
	if _, err := tx.Exec(
		ctx,
		`UPDATE sandbox_commands
		 SET state = $2, exit_code = $3, stdout = $4, stderr = $5,
		     output_truncated = $6, error_code = $7, started_at = $8,
		     completed_at = $9, updated_at = $10
		 WHERE id = $1`,
		command.ID,
		command.State,
		command.ExitCode,
		command.StandardOutput,
		command.StandardError,
		command.OutputTruncated,
		command.ErrorCode,
		command.StartedAt,
		command.CompletedAt,
		command.UpdatedAt,
	); err != nil {
		return nil, fmt.Errorf("update sandbox command result: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, fmt.Errorf("commit sandbox command result: %w", err)
	}
	return command, nil
}

func insertSandboxOperation(
	ctx context.Context,
	tx pgx.Tx,
	operation *SandboxOperation,
) error {
	if _, err := tx.Exec(
		ctx,
		`INSERT INTO sandbox_host_operations (
			id, sandbox_id, account_id, kind, state, generation,
			fencing_token, previous_sandbox_state,
			delete_after_stop, requested_lease_expires_at, error_code,
			created_at, updated_at
		) VALUES (
			$1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13
		)`,
		operation.ID,
		operation.SandboxID,
		operation.AccountID,
		operation.Kind,
		operation.State,
		operation.Generation,
		operation.FencingToken,
		operation.PreviousSandboxState,
		operation.DeleteAfterStop,
		operation.RequestedLeaseExpiresAt,
		operation.ErrorCode,
		operation.CreatedAt,
		operation.UpdatedAt,
	); err != nil {
		return sandboxPostgresError("insert sandbox operation", err)
	}
	return nil
}

func getSandboxCommandByIdempotency(
	ctx context.Context,
	tx pgx.Tx,
	accountID string,
	sandboxID string,
	idempotencyKey string,
) (*SandboxCommand, error) {
	return scanSandboxCommand(tx.QueryRow(
		ctx,
		`SELECT `+sandboxCommandSelectColumns+`
		 FROM sandbox_commands
		 WHERE account_id = $1 AND sandbox_id = $2 AND idempotency_key = $3`,
		accountID,
		sandboxID,
		idempotencyKey,
	))
}

func scanSandboxRecord(row rowScanner) (*SandboxRecord, error) {
	var record SandboxRecord
	if err := row.Scan(
		&record.ID,
		&record.AccountID,
		&record.CreatedByKeyID,
		&record.HostID,
		&record.Generation,
		&record.FencingToken,
		&record.BaseImageID,
		&record.CPUCount,
		&record.MemoryBytes,
		&record.WorkspaceBytes,
		&record.CommandTimeoutSeconds,
		&record.GPU,
		&record.State,
		&record.TerminationRequested,
		&record.LeaseExpiresAt,
		&record.ErrorCode,
		&record.CreatedAt,
		&record.UpdatedAt,
	); err != nil {
		return nil, err
	}
	return &record, nil
}

func scanSandboxOperation(row rowScanner) (*SandboxOperation, error) {
	var operation SandboxOperation
	if err := row.Scan(
		&operation.ID,
		&operation.SandboxID,
		&operation.AccountID,
		&operation.Kind,
		&operation.State,
		&operation.Generation,
		&operation.FencingToken,
		&operation.PreviousSandboxState,
		&operation.DeleteAfterStop,
		&operation.RequestedLeaseExpiresAt,
		&operation.ErrorCode,
		&operation.CreatedAt,
		&operation.UpdatedAt,
	); err != nil {
		return nil, err
	}
	return &operation, nil
}

func scanSandboxCommand(row rowScanner) (*SandboxCommand, error) {
	var (
		command     SandboxCommand
		arguments   []byte
		environment []byte
	)
	if err := row.Scan(
		&command.ID,
		&command.SandboxID,
		&command.AccountID,
		&command.IdempotencyKey,
		&command.Generation,
		&command.FencingToken,
		&arguments,
		&environment,
		&command.WorkingDirectory,
		&command.TimeoutSeconds,
		&command.State,
		&command.ExitCode,
		&command.StandardOutput,
		&command.StandardError,
		&command.OutputTruncated,
		&command.ErrorCode,
		&command.CreatedAt,
		&command.StartedAt,
		&command.CompletedAt,
		&command.UpdatedAt,
	); err != nil {
		return nil, err
	}
	if err := json.Unmarshal(arguments, &command.Arguments); err != nil {
		return nil, fmt.Errorf("decode sandbox command arguments: %w", err)
	}
	if string(environment) != "null" {
		if err := json.Unmarshal(environment, &command.Environment); err != nil {
			return nil, fmt.Errorf("decode sandbox command environment: %w", err)
		}
	}
	return &command, nil
}

func sandboxPostgresError(operation string, err error) error {
	var postgresError *pgconn.PgError
	if errors.As(err, &postgresError) &&
		(postgresError.Code == "23505" || postgresError.Code == "23514") {
		return fmt.Errorf("%s: %w", operation, ErrSandboxConflict)
	}
	return fmt.Errorf("%s: %w", operation, err)
}
