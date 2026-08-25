package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

const sandboxSelectColumns = `
	id::text, account_id, created_by_key_id, idempotency_key::text, host_id::text,
	generation, fencing_token, base_image_id, cpu_count, memory_bytes,
	workspace_bytes, command_timeout_seconds, gpu, state, termination_requested,
	termination_idempotency_key, lease_expires_at, error_code, created_at,
	updated_at`

const sandboxOperationSelectColumns = `
	id::text, sandbox_id::text, account_id, idempotency_key, kind, state,
	generation, fencing_token, previous_sandbox_state, delete_after_stop,
	requested_lease_expires_at, error_code, dispatch_attempts,
	last_dispatched_at, last_dispatch_error, created_at, updated_at`

const sandboxCommandSelectColumns = `
	id::text, sandbox_id::text, account_id, idempotency_key, generation,
	fencing_token, arguments, environment, working_directory, timeout_seconds,
	state, exit_code, stdout, stderr, output_truncated, error_code,
	dispatch_attempts, last_dispatched_at, last_dispatch_error, created_at,
	started_at, completed_at, updated_at`

func (s *PostgresStore) CreateSandbox(
	ctx context.Context,
	sandbox *SandboxRecord,
	operation *SandboxOperation,
	limits SandboxAllocationLimits,
) (*SandboxRecord, *SandboxOperation, bool, error) {
	if err := validateSandboxCreate(sandbox, operation); err != nil {
		return nil, nil, false, err
	}
	if limits.MaximumActive <= 0 ||
		limits.MaximumPerAccount <= 0 ||
		limits.MaximumPerHost <= 0 {
		return nil, nil, false, ErrSandboxInvalidTransition
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, nil, false, fmt.Errorf("begin sandbox create: %w", err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	if _, err := tx.Exec(
		ctx,
		`SELECT pg_advisory_xact_lock(736226839154274003)`,
	); err != nil {
		return nil, nil, false, fmt.Errorf(
			"lock sandbox allocation: %w",
			err,
		)
	}
	existing, err := scanSandboxRecord(tx.QueryRow(
		ctx,
		`SELECT `+sandboxSelectColumns+`
		 FROM sandboxes
		 WHERE account_id = $1 AND idempotency_key = $2`,
		sandbox.AccountID,
		sandbox.IdempotencyKey,
	))
	if err == nil {
		existingOperation, operationErr := scanSandboxOperation(tx.QueryRow(
			ctx,
			`SELECT `+sandboxOperationSelectColumns+`
			 FROM sandbox_host_operations
			 WHERE sandbox_id = $1 AND kind = $2
			 ORDER BY created_at
			 LIMIT 1`,
			existing.ID,
			SandboxOperationKindPrepare,
		))
		if operationErr != nil {
			return nil, nil, false, operationErr
		}
		return existing, existingOperation, false, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return nil, nil, false, err
	}
	var active, accountActive, hostActive int
	if err := tx.QueryRow(
		ctx,
		`SELECT
			COUNT(*),
			COUNT(*) FILTER (WHERE account_id = $1),
			COUNT(*) FILTER (WHERE host_id = $2)
		 FROM sandboxes
		 WHERE state <> $3`,
		sandbox.AccountID,
		sandbox.HostID,
		SandboxStateDeleted,
	).Scan(&active, &accountActive, &hostActive); err != nil {
		return nil, nil, false, fmt.Errorf(
			"count sandbox allocations: %w",
			err,
		)
	}
	if active >= limits.MaximumActive ||
		accountActive >= limits.MaximumPerAccount ||
		hostActive >= limits.MaximumPerHost {
		return nil, nil, false, ErrSandboxCapacity
	}
	if _, err := tx.Exec(
		ctx,
		`INSERT INTO sandboxes (
			id, account_id, created_by_key_id, idempotency_key, host_id,
			generation, fencing_token, base_image_id, cpu_count,
			memory_bytes, workspace_bytes, command_timeout_seconds, gpu,
			state, termination_requested, termination_idempotency_key,
			lease_expires_at, error_code, created_at, updated_at
		) VALUES (
			$1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13,
			$14, $15, $16, $17, $18, $19, $20
		)`,
		sandbox.ID,
		sandbox.AccountID,
		sandbox.CreatedByKeyID,
		sandbox.IdempotencyKey,
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
		sandbox.TerminationIdempotencyKey,
		sandbox.LeaseExpiresAt,
		sandbox.ErrorCode,
		sandbox.CreatedAt,
		sandbox.UpdatedAt,
	); err != nil {
		return nil, nil, false, sandboxPostgresError(
			"insert sandbox",
			err,
		)
	}
	if err := insertSandboxOperation(ctx, tx, operation); err != nil {
		return nil, nil, false, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, nil, false, fmt.Errorf("commit sandbox create: %w", err)
	}
	return cloneSandboxRecord(sandbox),
		cloneSandboxOperation(operation),
		true,
		nil
}

func (s *PostgresStore) GetSandboxByIdempotency(
	ctx context.Context,
	accountID string,
	idempotencyKey string,
) (*SandboxRecord, *SandboxOperation, error) {
	sandbox, err := scanSandboxRecord(s.pool.QueryRow(
		ctx,
		`SELECT `+sandboxSelectColumns+`
		 FROM sandboxes
		 WHERE account_id = $1 AND idempotency_key = $2`,
		accountID,
		idempotencyKey,
	))
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil, ErrNotFound
	}
	if err != nil {
		return nil, nil, err
	}
	operation, err := scanSandboxOperation(s.pool.QueryRow(
		ctx,
		`SELECT `+sandboxOperationSelectColumns+`
		 FROM sandbox_host_operations
		 WHERE sandbox_id = $1 AND kind = $2
		 ORDER BY created_at
		 LIMIT 1`,
		sandbox.ID,
		SandboxOperationKindPrepare,
	))
	if err != nil {
		return nil, nil, err
	}
	return sandbox, operation, nil
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
		 WHERE host_id = $1 AND state <> $2
		 ORDER BY created_at`,
		hostID,
		SandboxStateDeleted,
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

func (s *PostgresStore) ListExpiringSandboxes(
	ctx context.Context,
	expiresBefore time.Time,
	limit int,
) ([]SandboxRecord, error) {
	rows, err := s.pool.Query(
		ctx,
		`SELECT `+sandboxSelectColumns+`
		 FROM sandboxes
		 WHERE state <> $1 AND lease_expires_at <= $2
		 ORDER BY lease_expires_at
		 LIMIT $3`,
		SandboxStateDeleted,
		expiresBefore,
		sandboxListLimit(limit),
	)
	if err != nil {
		return nil, fmt.Errorf("list expiring sandboxes: %w", err)
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
		return nil, fmt.Errorf("list expiring sandboxes: %w", err)
	}
	return result, nil
}

func (s *PostgresStore) BeginSandboxOperation(
	ctx context.Context,
	operation *SandboxOperation,
	targetState string,
) (*SandboxRecord, *SandboxOperation, bool, error) {
	if err := validateSandboxOperationStart(operation, targetState); err != nil {
		return nil, nil, false, err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, nil, false, fmt.Errorf("begin sandbox operation: %w", err)
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
		return nil, nil, false, fmt.Errorf(
			"sandbox %s: %w",
			operation.SandboxID,
			ErrNotFound,
		)
	}
	if err != nil {
		return nil, nil, false, err
	}
	existing, err := scanSandboxOperation(tx.QueryRow(
		ctx,
		`SELECT `+sandboxOperationSelectColumns+`
		 FROM sandbox_host_operations
		 WHERE account_id = $1
		   AND sandbox_id = $2
		   AND idempotency_key = $3`,
		operation.AccountID,
		operation.SandboxID,
		operation.IdempotencyKey,
	))
	if err == nil {
		return sandbox, existing, false, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return nil, nil, false, err
	}
	if sandbox.Generation != operation.Generation ||
		sandbox.FencingToken != operation.FencingToken ||
		sandbox.State != operation.PreviousSandboxState ||
		sandbox.Terminal() ||
		(sandbox.TerminationRequested &&
			operation.Kind == SandboxOperationKindRenew) {
		return nil, nil, false, ErrSandboxConflict
	}
	var activeCommand bool
	if err := tx.QueryRow(
		ctx,
		`SELECT EXISTS (
				SELECT 1
				FROM sandbox_commands
				WHERE sandbox_id = $1
				  AND state NOT IN (
					'succeeded', 'failed', 'timed_out', 'cancelled', 'lost'
				  )
			)`,
		sandbox.ID,
	).Scan(&activeCommand); err != nil {
		return nil, nil, false, fmt.Errorf(
			"check active sandbox commands: %w",
			err,
		)
	}
	if activeCommand &&
		!(operation.Kind == SandboxOperationKindStop &&
			operation.DeleteAfterStop &&
			sandbox.TerminationRequested) {
		return nil, nil, false, ErrSandboxConflict
	}
	if err := insertSandboxOperation(ctx, tx, operation); err != nil {
		return nil, nil, false, err
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
		return nil, nil, false, fmt.Errorf(
			"update sandbox operation state: %w",
			err,
		)
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, nil, false, fmt.Errorf(
			"commit sandbox operation: %w",
			err,
		)
	}
	return sandbox, cloneSandboxOperation(operation), true, nil
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

func (s *PostgresStore) GetSandboxOperationByIdempotency(
	ctx context.Context,
	accountID string,
	sandboxID string,
	idempotencyKey string,
) (*SandboxOperation, error) {
	operation, err := scanSandboxOperation(s.pool.QueryRow(
		ctx,
		`SELECT `+sandboxOperationSelectColumns+`
		 FROM sandbox_host_operations
		 WHERE account_id = $1
		   AND sandbox_id = $2
		   AND idempotency_key = $3`,
		accountID,
		sandboxID,
		idempotencyKey,
	))
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, fmt.Errorf(
			"sandbox operation idempotency key: %w",
			ErrNotFound,
		)
	}
	return operation, err
}

func (s *PostgresStore) MarkSandboxTerminationRequested(
	ctx context.Context,
	accountID string,
	sandboxID string,
	idempotencyKey string,
	at time.Time,
) (*SandboxRecord, error) {
	if !validSandboxUUID(idempotencyKey) || at.IsZero() {
		return nil, ErrSandboxInvalidTransition
	}
	record, err := scanSandboxRecord(s.pool.QueryRow(
		ctx,
		`UPDATE sandboxes
		 SET termination_requested = TRUE,
		     termination_idempotency_key = CASE
		       WHEN termination_idempotency_key = '' THEN $3
		       ELSE termination_idempotency_key
		     END,
		     updated_at = CASE
		       WHEN state = $5 THEN updated_at
		       ELSE $4
		     END
		 WHERE id = $1
		   AND account_id = $2
		   AND (
		     termination_idempotency_key = ''
		     OR termination_idempotency_key = $3
		   )
		 RETURNING `+sandboxSelectColumns,
		sandboxID,
		accountID,
		idempotencyKey,
		at,
		SandboxStateDeleted,
	))
	if errors.Is(err, pgx.ErrNoRows) {
		var exists bool
		if scanErr := s.pool.QueryRow(
			ctx,
			`SELECT EXISTS (
				SELECT 1 FROM sandboxes WHERE id = $1 AND account_id = $2
			)`,
			sandboxID,
			accountID,
		).Scan(&exists); scanErr != nil {
			return nil, scanErr
		}
		if exists {
			return nil, ErrSandboxConflict
		}
		return nil, fmt.Errorf("sandbox %s: %w", sandboxID, ErrNotFound)
	}
	return record, err
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
	if sandbox.State != SandboxStateReady ||
		sandbox.TerminationRequested ||
		sandbox.Generation != command.Generation ||
		sandbox.FencingToken != command.FencingToken ||
		command.CreatedAt.Add(
			time.Duration(command.TimeoutSeconds)*time.Second,
		).After(sandbox.LeaseExpiresAt) {
		return nil, false, ErrSandboxConflict
	}
	var activeOperation, activeCommand bool
	if err := tx.QueryRow(
		ctx,
		`SELECT
		   EXISTS (
		     SELECT 1
		     FROM sandbox_host_operations
		     WHERE sandbox_id = $1
		       AND state NOT IN ('ready', 'stopped', 'deleted', 'failed')
		   ),
		   EXISTS (
		     SELECT 1
		     FROM sandbox_commands
		     WHERE sandbox_id = $1
		       AND state NOT IN (
		         'succeeded', 'failed', 'timed_out', 'cancelled', 'lost'
		       )
		   )`,
		sandbox.ID,
	).Scan(&activeOperation, &activeCommand); err != nil {
		return nil, false, fmt.Errorf(
			"check active sandbox work: %w",
			err,
		)
	}
	if activeOperation || activeCommand {
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

func (s *PostgresStore) ListActiveSandboxCommands(
	ctx context.Context,
	sandboxID string,
) ([]SandboxCommand, error) {
	rows, err := s.pool.Query(
		ctx,
		`SELECT `+sandboxCommandSelectColumns+`
		 FROM sandbox_commands
		 WHERE sandbox_id = $1
		   AND state NOT IN (
		     'succeeded', 'failed', 'timed_out', 'cancelled', 'lost'
		   )
		 ORDER BY created_at`,
		sandboxID,
	)
	if err != nil {
		return nil, fmt.Errorf("list active sandbox commands: %w", err)
	}
	defer rows.Close()
	result := make([]SandboxCommand, 0)
	for rows.Next() {
		command, err := scanSandboxCommand(rows)
		if err != nil {
			return nil, err
		}
		result = append(result, *command)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("list active sandbox commands: %w", err)
	}
	return result, nil
}

func (s *PostgresStore) ListExpiringSandboxCommands(
	ctx context.Context,
	expiresBefore time.Time,
	limit int,
) ([]PendingSandboxCommand, error) {
	rows, err := s.pool.Query(
		ctx,
		`SELECT `+sandboxCommandSelectColumns+`
		 FROM sandbox_commands
		 WHERE state NOT IN (
		   'succeeded', 'failed', 'timed_out', 'cancelled', 'lost'
		 )
		   AND created_at
		     + make_interval(secs => timeout_seconds::double precision) <= $1
		 ORDER BY created_at
		     + make_interval(secs => timeout_seconds::double precision)
		 LIMIT $2`,
		expiresBefore,
		sandboxListLimit(limit),
	)
	if err != nil {
		return nil, fmt.Errorf("list expiring sandbox commands: %w", err)
	}
	commands := make([]SandboxCommand, 0)
	for rows.Next() {
		command, scanErr := scanSandboxCommand(rows)
		if scanErr != nil {
			rows.Close()
			return nil, scanErr
		}
		commands = append(commands, *command)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return nil, fmt.Errorf("list expiring sandbox commands: %w", err)
	}
	rows.Close()

	result := make([]PendingSandboxCommand, 0, len(commands))
	for index := range commands {
		sandbox, err := s.GetSandboxByID(ctx, commands[index].SandboxID)
		if err != nil {
			return nil, err
		}
		result = append(result, PendingSandboxCommand{
			Sandbox: *sandbox,
			Command: commands[index],
		})
	}
	return result, nil
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

func (s *PostgresStore) RecordSandboxOperationDispatch(
	ctx context.Context,
	operationID string,
	dispatchedAt time.Time,
	dispatchError string,
) error {
	tag, err := s.pool.Exec(
		ctx,
		`UPDATE sandbox_host_operations
		 SET dispatch_attempts = dispatch_attempts + 1,
		     last_dispatched_at = $2,
		     last_dispatch_error = $3,
		     updated_at = GREATEST(updated_at, $2)
		 WHERE id = $1`,
		operationID,
		dispatchedAt,
		dispatchError,
	)
	if err != nil {
		return fmt.Errorf("record sandbox operation dispatch: %w", err)
	}
	if tag.RowsAffected() != 1 {
		return ErrNotFound
	}
	return nil
}

func (s *PostgresStore) ListPendingSandboxOperationsByHost(
	ctx context.Context,
	hostID string,
) ([]PendingSandboxOperation, error) {
	rows, err := s.pool.Query(
		ctx,
		`SELECT `+sandboxOperationSelectColumns+`
		 FROM sandbox_host_operations
		 WHERE sandbox_id IN (
		   SELECT id FROM sandboxes WHERE host_id = $1 AND state <> $2
		 )
		   AND state NOT IN ($3, $4, $5, $6)
		 ORDER BY created_at`,
		hostID,
		SandboxStateDeleted,
		SandboxOperationReady,
		SandboxOperationStopped,
		SandboxOperationDeleted,
		SandboxOperationFailed,
	)
	if err != nil {
		return nil, fmt.Errorf("list pending sandbox operations: %w", err)
	}
	operations := make([]SandboxOperation, 0)
	for rows.Next() {
		operation, err := scanSandboxOperation(rows)
		if err != nil {
			rows.Close()
			return nil, err
		}
		operations = append(operations, *operation)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return nil, fmt.Errorf("list pending sandbox operations: %w", err)
	}
	rows.Close()

	result := make([]PendingSandboxOperation, 0, len(operations))
	for index := range operations {
		sandbox, err := s.GetSandboxByID(ctx, operations[index].SandboxID)
		if err != nil {
			return nil, err
		}
		result = append(result, PendingSandboxOperation{
			Sandbox:   *sandbox,
			Operation: operations[index],
		})
	}
	return result, nil
}

func (s *PostgresStore) RecordSandboxCommandDispatch(
	ctx context.Context,
	commandID string,
	dispatchedAt time.Time,
	dispatchError string,
) error {
	tag, err := s.pool.Exec(
		ctx,
		`UPDATE sandbox_commands
		 SET dispatch_attempts = dispatch_attempts + 1,
		     last_dispatched_at = $2,
		     last_dispatch_error = $3,
		     updated_at = GREATEST(updated_at, $2)
		 WHERE id = $1`,
		commandID,
		dispatchedAt,
		dispatchError,
	)
	if err != nil {
		return fmt.Errorf("record sandbox command dispatch: %w", err)
	}
	if tag.RowsAffected() != 1 {
		return ErrNotFound
	}
	return nil
}

func (s *PostgresStore) ListPendingSandboxCommandsByHost(
	ctx context.Context,
	hostID string,
) ([]PendingSandboxCommand, error) {
	rows, err := s.pool.Query(
		ctx,
		`SELECT `+sandboxCommandSelectColumns+`
		 FROM sandbox_commands
		 WHERE sandbox_id IN (
		   SELECT id FROM sandboxes WHERE host_id = $1 AND state <> $2
		 )
		   AND state NOT IN ($3, $4, $5, $6, $7)
		 ORDER BY created_at`,
		hostID,
		SandboxStateDeleted,
		SandboxCommandSucceeded,
		SandboxCommandFailed,
		SandboxCommandTimedOut,
		SandboxCommandCancelled,
		SandboxCommandLost,
	)
	if err != nil {
		return nil, fmt.Errorf("list pending sandbox commands: %w", err)
	}
	commands := make([]SandboxCommand, 0)
	for rows.Next() {
		command, err := scanSandboxCommand(rows)
		if err != nil {
			rows.Close()
			return nil, err
		}
		commands = append(commands, *command)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return nil, fmt.Errorf("list pending sandbox commands: %w", err)
	}
	rows.Close()

	result := make([]PendingSandboxCommand, 0, len(commands))
	for index := range commands {
		sandbox, err := s.GetSandboxByID(ctx, commands[index].SandboxID)
		if err != nil {
			return nil, err
		}
		result = append(result, PendingSandboxCommand{
			Sandbox: *sandbox,
			Command: commands[index],
		})
	}
	return result, nil
}

func insertSandboxOperation(
	ctx context.Context,
	tx pgx.Tx,
	operation *SandboxOperation,
) error {
	if _, err := tx.Exec(
		ctx,
		`INSERT INTO sandbox_host_operations (
			id, sandbox_id, account_id, idempotency_key, kind, state,
			generation, fencing_token, previous_sandbox_state,
			delete_after_stop, requested_lease_expires_at, error_code,
			created_at, updated_at
		) VALUES (
			$1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13,
			$14
		)`,
		operation.ID,
		operation.SandboxID,
		operation.AccountID,
		operation.IdempotencyKey,
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
		&record.IdempotencyKey,
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
		&record.TerminationIdempotencyKey,
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
		&operation.IdempotencyKey,
		&operation.Kind,
		&operation.State,
		&operation.Generation,
		&operation.FencingToken,
		&operation.PreviousSandboxState,
		&operation.DeleteAfterStop,
		&operation.RequestedLeaseExpiresAt,
		&operation.ErrorCode,
		&operation.DispatchAttempts,
		&operation.LastDispatchedAt,
		&operation.LastDispatchError,
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
		&command.DispatchAttempts,
		&command.LastDispatchedAt,
		&command.LastDispatchError,
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
