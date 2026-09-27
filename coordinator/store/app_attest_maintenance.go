package store

import (
	"context"
	"time"
)

// Reconciliation never replays a signature into a live credential counter or
// rewrites a rejection as an acceptance. New live challenges recover trust.
type AppAttestMaintenanceStore interface {
	ReconcileAppAttestEvidence(context.Context, time.Time, int) (int64, error)
	QueueAppAttestReceiptRecovery(context.Context, int) (int64, error)
}

func (s *PostgresStore) ReconcileAppAttestEvidence(ctx context.Context, before time.Time, limit int) (int64, error) {
	limit = maintenanceLimit(limit)
	tag, err := s.pool.Exec(ctx, `WITH stale AS (
	 SELECT id FROM app_attest_evidence WHERE outcome='pending' AND received_at<$1
	 ORDER BY received_at FOR UPDATE SKIP LOCKED LIMIT $2)
	 UPDATE app_attest_evidence e SET outcome='interrupted',completed_at=NOW(),
	 details=e.details || '{"reconciled_from":"pending","requires_fresh_exchange":true}'::jsonb
	 FROM stale WHERE e.id=stale.id AND e.outcome='pending'`, before, limit)
	return tag.RowsAffected(), err
}

func (s *PostgresStore) QueueAppAttestReceiptRecovery(ctx context.Context, limit int) (int64, error) {
	// Old releases retained stale receipts but never queued renewal. Only seed
	// recovery from accepted attestations with a durable matching credential.
	// The worker independently verifies every receipt before contacting Apple.
	tag, err := s.pool.Exec(ctx, `INSERT INTO app_attest_receipt_jobs(key_id,receipt_id,next_at)
	 SELECT key_id,id,NOW() FROM (
	 SELECT DISTINCT ON (r.key_id) r.key_id,r.id FROM app_attest_receipts r
	 JOIN app_attest_evidence e ON e.id=r.evidence_id AND e.outcome='verified'
	 JOIN app_attest_shadow_keys k ON k.key_id=r.key_id
	 WHERE r.outcome='receipt_creation_time' AND NOT EXISTS(
	 SELECT 1 FROM app_attest_receipt_jobs j WHERE j.key_id=r.key_id)
	 ORDER BY r.key_id,r.received_at DESC,r.id LIMIT $1) candidates
	 ON CONFLICT(key_id) DO NOTHING`, maintenanceLimit(limit))
	return tag.RowsAffected(), err
}

func maintenanceLimit(limit int) int {
	if limit < 1 || limit > 100 {
		return 100
	}
	return limit
}
