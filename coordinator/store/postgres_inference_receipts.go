package store

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

var _ InferenceReceiptStore = (*PostgresStore)(nil)

const inferenceReceiptTableDDL = `CREATE TABLE IF NOT EXISTS inference_receipts (
	job_id TEXT PRIMARY KEY CHECK (job_id <> ''),
	nonce TEXT NOT NULL,
	receipt_hash TEXT,
	state TEXT NOT NULL CHECK (state IN ('pending', 'completed', 'failed', 'interrupted')),
	envelope BYTEA,
	created_at TIMESTAMPTZ NOT NULL,
	updated_at TIMESTAMPTZ NOT NULL,
	expires_at TIMESTAMPTZ NOT NULL,
	CHECK (
		(state = 'completed' AND receipt_hash IS NOT NULL AND receipt_hash <> '' AND envelope IS NOT NULL AND octet_length(envelope) > 0)
		OR (state <> 'completed' AND receipt_hash IS NULL AND envelope IS NULL)
	)
);
ALTER TABLE inference_receipts ADD COLUMN IF NOT EXISTS nonce TEXT;
CREATE INDEX IF NOT EXISTS idx_inference_receipts_expires ON inference_receipts(expires_at);
CREATE INDEX IF NOT EXISTS idx_inference_receipts_pending_created ON inference_receipts(created_at, job_id) WHERE state = 'pending';
CREATE UNIQUE INDEX IF NOT EXISTS idx_inference_receipts_hash ON inference_receipts(receipt_hash) WHERE receipt_hash IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_inference_receipts_nonce ON inference_receipts(nonce)`

func (s *PostgresStore) CreateInferenceReceipt(ctx context.Context, rec InferenceReceiptRecord) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	rec, err := normalizeInferenceReceipt(rec)
	if err != nil {
		return err
	}
	var receiptHash any
	if rec.ReceiptHash != "" {
		receiptHash = rec.ReceiptHash
	}
	var envelope any
	if len(rec.Envelope) > 0 {
		envelope = rec.Envelope
	}
	_, err = s.pool.Exec(ctx, `INSERT INTO inference_receipts
		(job_id, nonce, receipt_hash, state, envelope, created_at, updated_at, expires_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
		rec.JobID, rec.Nonce, receiptHash, rec.State, envelope, rec.CreatedAt, rec.UpdatedAt, rec.ExpiresAt)
	return inferenceReceiptWriteError(err)
}

func (s *PostgresStore) CompleteInferenceReceipt(ctx context.Context, jobID, receiptHash string, envelope []byte, completedAt, expiresAt time.Time) (bool, error) {
	if err := ctx.Err(); err != nil {
		return false, err
	}
	if err := validateInferenceReceiptCompletion(jobID, receiptHash, envelope, completedAt, expiresAt); err != nil {
		return false, err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return false, err
	}
	defer tx.Rollback(ctx)
	var state string
	var createdAt time.Time
	if err := tx.QueryRow(ctx, `SELECT state, created_at FROM inference_receipts WHERE job_id = $1 FOR UPDATE`, jobID).Scan(&state, &createdAt); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return false, ErrNotFound
		}
		return false, err
	}
	if state != InferenceReceiptPending {
		return false, nil
	}
	if err := validateInferenceReceiptLifecycleTime(createdAt, completedAt); err != nil {
		return false, err
	}
	tag, err := tx.Exec(ctx, `UPDATE inference_receipts
		SET receipt_hash = $2, state = 'completed', envelope = $3, updated_at = $4, expires_at = $5
		WHERE job_id = $1 AND state = 'pending'`,
		jobID, receiptHash, cloneReceiptEnvelope(envelope), completedAt, expiresAt)
	if err != nil {
		return false, inferenceReceiptWriteError(err)
	}
	if tag.RowsAffected() != 1 {
		return false, nil
	}
	if err := tx.Commit(ctx); err != nil {
		return false, err
	}
	return true, nil
}

func (s *PostgresStore) SetInferenceReceiptState(ctx context.Context, jobID, state string, updatedAt time.Time) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if strings.TrimSpace(jobID) == "" {
		return errors.New("store: inference receipt job ID is required")
	}
	if state != InferenceReceiptFailed && state != InferenceReceiptInterrupted {
		return errors.New("store: inference receipt state can only be failed or interrupted")
	}
	if updatedAt.IsZero() {
		return errors.New("store: inference receipt updated_at is required")
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	var currentState string
	var createdAt time.Time
	if err := tx.QueryRow(ctx, `SELECT state, created_at FROM inference_receipts WHERE job_id = $1 FOR UPDATE`, jobID).Scan(&currentState, &createdAt); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		return err
	}
	if currentState != InferenceReceiptPending {
		return nil
	}
	if err := validateInferenceReceiptLifecycleTime(createdAt, updatedAt); err != nil {
		return err
	}
	tag, err := tx.Exec(ctx, `UPDATE inference_receipts SET state = $2, updated_at = $3
		WHERE job_id = $1 AND state = 'pending'`, jobID, state, updatedAt)
	if err != nil {
		return err
	}
	if tag.RowsAffected() != 1 {
		return nil
	}
	return tx.Commit(ctx)
}

func (s *PostgresStore) GetInferenceReceiptByJobID(ctx context.Context, jobID string) (InferenceReceiptRecord, error) {
	if err := ctx.Err(); err != nil {
		return InferenceReceiptRecord{}, err
	}
	if strings.TrimSpace(jobID) == "" {
		return InferenceReceiptRecord{}, ErrNotFound
	}
	return scanInferenceReceipt(s.pool.QueryRow(ctx, inferenceReceiptSelect+` WHERE job_id = $1`, jobID))
}

func (s *PostgresStore) GetInferenceReceiptByHash(ctx context.Context, receiptHash string) (InferenceReceiptRecord, error) {
	if err := ctx.Err(); err != nil {
		return InferenceReceiptRecord{}, err
	}
	if strings.TrimSpace(receiptHash) == "" {
		return InferenceReceiptRecord{}, ErrNotFound
	}
	return scanInferenceReceipt(s.pool.QueryRow(ctx, inferenceReceiptSelect+` WHERE receipt_hash = $1 AND state = 'completed' AND expires_at > $2`, receiptHash, time.Now().UTC()))
}

func (s *PostgresStore) InterruptStaleInferenceReceipts(ctx context.Context, staleBefore, interruptedAt time.Time, limit int) (int, error) {
	if err := ctx.Err(); err != nil {
		return 0, err
	}
	if interruptedAt.IsZero() {
		return 0, errors.New("store: inference receipt interruption time is required")
	}
	limit = inferenceReceiptLimit(limit)
	if limit == 0 {
		return 0, nil
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(ctx)
	rows, err := tx.Query(ctx, `SELECT job_id, created_at FROM inference_receipts
		WHERE state = 'pending' AND created_at <= $1
		ORDER BY created_at, job_id
		LIMIT $2
		FOR UPDATE SKIP LOCKED`, staleBefore, limit)
	if err != nil {
		return 0, err
	}
	jobIDs := make([]string, 0, limit)
	for rows.Next() {
		var jobID string
		var createdAt time.Time
		if err := rows.Scan(&jobID, &createdAt); err != nil {
			rows.Close()
			return 0, err
		}
		if err := validateInferenceReceiptLifecycleTime(createdAt, interruptedAt); err != nil {
			rows.Close()
			return 0, err
		}
		jobIDs = append(jobIDs, jobID)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return 0, err
	}
	rows.Close()
	if len(jobIDs) == 0 {
		return 0, nil
	}
	tag, err := tx.Exec(ctx, `UPDATE inference_receipts
		SET state = 'interrupted', updated_at = $2
		WHERE job_id = ANY($1::text[]) AND state = 'pending'`, jobIDs, interruptedAt)
	if err != nil {
		return 0, err
	}
	if int(tag.RowsAffected()) != len(jobIDs) {
		return 0, errors.New("store: stale inference receipt batch changed while locked")
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, err
	}
	return len(jobIDs), nil
}

func (s *PostgresStore) PruneInferenceReceipts(ctx context.Context, before time.Time, limit int) (int, error) {
	if err := ctx.Err(); err != nil {
		return 0, err
	}
	limit = inferenceReceiptLimit(limit)
	if limit == 0 {
		return 0, nil
	}
	tag, err := s.pool.Exec(ctx, `WITH expired AS (
		SELECT job_id FROM inference_receipts
		WHERE state IN ('pending', 'completed', 'failed', 'interrupted') AND expires_at <= $1
		ORDER BY expires_at, job_id
		LIMIT $2
		FOR UPDATE SKIP LOCKED
	)
	DELETE FROM inference_receipts r USING expired e WHERE r.job_id = e.job_id`, before, limit)
	if err != nil {
		return 0, err
	}
	return int(tag.RowsAffected()), nil
}

const inferenceReceiptSelect = `SELECT job_id, COALESCE(nonce, ''), COALESCE(receipt_hash, ''), state,
	COALESCE(envelope, ''::bytea), created_at, updated_at, expires_at FROM inference_receipts`

func scanInferenceReceipt(row pgx.Row) (InferenceReceiptRecord, error) {
	var rec InferenceReceiptRecord
	if err := row.Scan(&rec.JobID, &rec.Nonce, &rec.ReceiptHash, &rec.State, &rec.Envelope, &rec.CreatedAt, &rec.UpdatedAt, &rec.ExpiresAt); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return InferenceReceiptRecord{}, ErrNotFound
		}
		return InferenceReceiptRecord{}, err
	}
	rec.Envelope = cloneReceiptEnvelope(rec.Envelope)
	return rec, nil
}

func inferenceReceiptWriteError(err error) error {
	if err == nil {
		return nil
	}
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23505" {
		return ErrInferenceReceiptConflict
	}
	return err
}
