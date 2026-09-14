package store

import (
	"context"
	"encoding/json"
	"fmt"
	"time"
)

// Select only request material needed for legacy commitment generation; never
// fetch old stdout/stderr into coordinator memory during maintenance. Each
// transaction is bounded and skips rows owned by concurrent result handlers.
func (s *PostgresStore) RedactSandboxCommandPayloads(ctx context.Context, completedBefore, redactedAt time.Time, limit int) (int, error) {
	if completedBefore.IsZero() || redactedAt.IsZero() || redactedAt.Before(completedBefore) {
		return 0, ErrSandboxInvalidTransition
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	if _, err := tx.Exec(ctx, `SELECT set_config('statement_timeout', '4s', true), set_config('lock_timeout', '1s', true)`); err != nil {
		return 0, err
	}
	rows, err := tx.Query(ctx, `SELECT id::text, sandbox_id::text, account_id,
		idempotency_key, arguments, environment, working_directory,
		timeout_seconds, state, request_digest
		FROM sandbox_commands
		WHERE NOT payload_expired AND NOT cancellation_pending
		  AND state IN ('succeeded', 'failed', 'timed_out', 'cancelled', 'lost')
		  AND completed_at <= $1
		ORDER BY completed_at, id LIMIT $2 FOR UPDATE SKIP LOCKED`, completedBefore, sandboxPayloadRedactionLimit(limit))
	if err != nil {
		return 0, fmt.Errorf("select expired sandbox payloads: %w", err)
	}
	commands := make([]SandboxCommand, 0)
	for rows.Next() {
		var command SandboxCommand
		var arguments, environment []byte
		if err := rows.Scan(&command.ID, &command.SandboxID, &command.AccountID, &command.IdempotencyKey,
			&arguments, &environment, &command.WorkingDirectory, &command.TimeoutSeconds, &command.State, &command.RequestDigest); err != nil {
			rows.Close()
			return 0, err
		}
		if err := json.Unmarshal(arguments, &command.Arguments); err != nil {
			rows.Close()
			return 0, err
		}
		if err := json.Unmarshal(environment, &command.Environment); err != nil {
			rows.Close()
			return 0, err
		}
		if err := redactSandboxCommandPayload(&command, redactedAt); err != nil {
			rows.Close()
			return 0, err
		}
		commands = append(commands, command)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return 0, err
	}
	for _, command := range commands {
		if _, err := tx.Exec(ctx, `UPDATE sandbox_commands
			SET arguments = '[]'::jsonb, environment = 'null'::jsonb,
			working_directory = '', stdout = '', stderr = '', request_digest = $2,
			payload_expired = TRUE, payload_expired_at = $3 WHERE id = $1`,
			command.ID, command.RequestDigest, redactedAt); err != nil {
			return 0, err
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, err
	}
	return len(commands), nil
}
