package store

import "context"

func (s *PostgresStore) ListSandboxCommands(ctx context.Context, accountID, sandboxID string, limit int) ([]SandboxCommandSummary, error) {
	if _, err := s.GetSandbox(ctx, accountID, sandboxID); err != nil {
		return nil, err
	}
	rows, err := s.pool.Query(ctx, `SELECT id, sandbox_id, state, timeout_seconds,
		exit_code, error_code, output_truncated, cancellation_pending,
		created_at, started_at, completed_at, payload_expired, payload_expired_at
		FROM sandbox_commands WHERE sandbox_id = $1 AND account_id = $2
		ORDER BY created_at DESC, id DESC LIMIT $3`, sandboxID, accountID, sandboxListLimit(limit))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]SandboxCommandSummary, 0)
	for rows.Next() {
		var summary SandboxCommandSummary
		if err := rows.Scan(&summary.ID, &summary.SandboxID, &summary.State, &summary.TimeoutSeconds,
			&summary.ExitCode, &summary.ErrorCode, &summary.OutputTruncated, &summary.CancellationPending,
			&summary.CreatedAt, &summary.StartedAt, &summary.CompletedAt, &summary.PayloadExpired, &summary.PayloadExpiredAt); err != nil {
			return nil, err
		}
		result = append(result, summary)
	}
	return result, rows.Err()
}
