package postgres

import (
	"context"
	"errors"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"github.com/jackc/pgx/v5"
)

func insertAppAttestReceipt(ctx context.Context, tx pgx.Tx, r contracts.AppAttestReceipt) error {
	_, err := tx.Exec(ctx, `INSERT INTO app_attest_receipts VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)`, r.ID, r.KeyID, r.EvidenceID, r.ParentID, r.ReceivedAt, r.Outcome, r.HTTPStatus, r.Details, r.Context, r.NextAt, r.ExpiresAt)
	if err != nil {
		return err
	}
	if r.Body == nil {
		r.Body = []byte{}
	}
	if r.ResponseBody == nil {
		r.ResponseBody = []byte{}
	}
	_, err = tx.Exec(ctx, `INSERT INTO app_attest_receipt_blobs VALUES($1,$2,$3)`, r.ID, r.Body, r.ResponseBody)
	if err != nil {
		return err
	}
	if r.Outcome == "verified" || r.Outcome == "renewal_required" {
		_, err = tx.Exec(ctx, `INSERT INTO app_attest_receipt_jobs(key_id,receipt_id,next_at) VALUES($1,$2,$3)
		 ON CONFLICT(key_id) DO UPDATE SET receipt_id=$2,next_at=$3,lease_until=NULL
		 WHERE app_attest_receipt_jobs.receipt_id=$4`, r.KeyID, r.ID, r.NextAt, r.ParentID)
	}
	return err
}

func (s *Store) ClaimAppAttestReceipt(ctx context.Context, now time.Time) (*contracts.AppAttestReceipt, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	var id string
	err = tx.QueryRow(ctx, `SELECT receipt_id FROM app_attest_receipt_jobs WHERE next_at<=$1 AND (lease_until IS NULL OR lease_until<$1) ORDER BY next_at FOR UPDATE SKIP LOCKED LIMIT 1`, now).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var r contracts.AppAttestReceipt
	err = tx.QueryRow(ctx, `SELECT r.id,r.key_id,r.evidence_id,r.parent_id,r.received_at,r.outcome,r.http_status,r.details,r.context,r.next_at,r.expires_at,b.body
	 FROM app_attest_receipts r JOIN app_attest_receipt_blobs b ON b.receipt_id=r.id WHERE r.id=$1`, id).Scan(&r.ID, &r.KeyID, &r.EvidenceID, &r.ParentID, &r.ReceivedAt, &r.Outcome, &r.HTTPStatus, &r.Details, &r.Context, &r.NextAt, &r.ExpiresAt, &r.Body)
	if err != nil {
		return nil, err
	}
	_, err = tx.Exec(ctx, `UPDATE app_attest_receipt_jobs SET lease_until=$2,attempts=attempts+1 WHERE receipt_id=$1`, id, now.Add(2*time.Minute))
	if err != nil {
		return nil, err
	}
	return &r, tx.Commit(ctx)
}

func (s *Store) SaveAppAttestReceiptRefresh(ctx context.Context, r contracts.AppAttestReceipt) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if err = insertAppAttestReceipt(ctx, tx, r); err != nil {
		return err
	}
	if r.Outcome != "verified" && r.Outcome != "renewal_required" {
		_, err = tx.Exec(ctx, `UPDATE app_attest_receipt_jobs SET next_at=$3,lease_until=NULL WHERE key_id=$1 AND receipt_id=$2`, r.KeyID, r.ParentID, r.NextAt)
		if err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}
