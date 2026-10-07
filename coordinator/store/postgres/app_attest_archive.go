package postgres

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/jackc/pgx/v5"
)

func (s *PostgresStore) BeginAppAttestEvidence(ctx context.Context, e store.AppAttestEvidence) error {
	tx, err := beginErasureObservation(ctx, s.pool)
	if err != nil {
		return err
	}
	defer rollbackErasureTx(tx)
	if err = checkPersonalSession(ctx, tx, e.SessionID, e.AccountID); err != nil {
		return err
	}
	if err = bindEvidenceAccount(ctx, tx, e.SessionID, e.AccountID); err != nil {
		return err
	}
	_, err = tx.Exec(ctx, `INSERT INTO app_attest_evidence(id,session_id,key_id,received_at,action,sha256,context) VALUES($1,$2,$3,$4,$5,$6,$7)`, e.ID, e.SessionID, e.KeyID, e.ReceivedAt, e.Action, e.SHA256, e.Context)
	if err != nil {
		return err
	}
	if e.Proof == nil {
		e.Proof = []byte{}
	}
	_, err = tx.Exec(ctx, `INSERT INTO app_attest_evidence_blobs VALUES($1,$2,$3)`, e.ID, e.ProofField, e.Proof)
	if err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func (s *PostgresStore) CompleteAppAttestEvidence(ctx context.Context, id string, d store.AppAttestDecision) (string, error) {
	tx, err := beginErasureObservation(ctx, s.pool)
	if err != nil {
		return "", err
	}
	defer rollbackErasureTx(tx)
	var outcome, session string
	err = tx.QueryRow(ctx, `SELECT outcome,session_id FROM app_attest_evidence WHERE id=$1 FOR UPDATE`, id).Scan(&outcome, &session)
	if err != nil {
		return "", err
	}
	if err = checkPersonalSession(ctx, tx, session, ""); err != nil {
		return "", err
	}
	if outcome != "pending" {
		return outcome, nil
	}
	outcome = d.Outcome
	if d.Key != nil && outcome == "verified" {
		raw, e := json.Marshal(d.Key)
		if e != nil {
			return "", e
		}
		tag, e := tx.Exec(ctx, `INSERT INTO app_attest_shadow_keys(key_id,owner,evidence) VALUES($1,$2,$3) ON CONFLICT DO NOTHING`, d.Key.KeyID, d.Key.Owner, raw)
		if e != nil {
			return "", e
		}
		if tag.RowsAffected() == 0 {
			// A repeated identical attestation is idempotent, but must never
			// replace an owner or reset an already advanced assertion counter.
			var oldRaw []byte
			if e = tx.QueryRow(ctx, `SELECT evidence FROM app_attest_shadow_keys WHERE key_id=$1`, d.Key.KeyID).Scan(&oldRaw); e != nil {
				return "", e
			}
			var old store.AppAttestShadowKey
			if json.Unmarshal(oldRaw, &old) != nil || old.Owner != d.Key.Owner || old.AppID != d.Key.AppID || old.Environment != d.Key.Environment || string(old.PublicKey) != string(d.Key.PublicKey) {
				outcome = "key_owner_or_policy"
			}
		}
	}
	if d.Counter != nil && outcome == "verified" {
		tag, e := tx.Exec(ctx, `UPDATE app_attest_shadow_keys SET counter=$3,updated_at=NOW() WHERE key_id=$1 AND owner=$2 AND counter<$3`, d.KeyID, d.Owner, *d.Counter)
		if e != nil {
			return "", e
		}
		if tag.RowsAffected() != 1 {
			outcome = "counter_conflict"
		}
	}
	if d.Receipt != nil {
		if outcome != "verified" && (d.Receipt.Outcome == "verified" || d.Receipt.Outcome == "renewal_required") {
			d.Receipt.Outcome = "attestation_not_accepted"
		}
		if err = insertAppAttestReceipt(ctx, tx, *d.Receipt); err != nil {
			return "", err
		}
	}
	if len(d.Details) == 0 {
		d.Details = json.RawMessage(`{}`)
	}
	var details map[string]any
	if err = json.Unmarshal(d.Details, &details); err != nil {
		return "", err
	}
	if details == nil {
		details = map[string]any{}
	}
	if d.Counter != nil && outcome == "verified" {
		details["accepted_counter"] = *d.Counter
	}
	d.Details, err = json.Marshal(details)
	if err != nil {
		return "", err
	}
	tag, err := tx.Exec(ctx, `UPDATE app_attest_evidence SET outcome=$2,details=$3,completed_at=NOW() WHERE id=$1 AND outcome='pending'`, id, outcome, d.Details)
	if err != nil {
		return "", err
	}
	if tag.RowsAffected() != 1 {
		return "", errors.New("evidence_completion_conflict")
	}
	return outcome, tx.Commit(ctx)
}

func (s *PostgresStore) GetAppAttestAssertionDiagnostics(ctx context.Context, keyID string) (*store.AppAttestAssertionDiagnostics, error) {
	var result store.AppAttestAssertionDiagnostics
	err := s.pool.QueryRow(ctx, `SELECT context->'boot_time',context->'process_started_at' FROM (
	 SELECT id,received_at,action,outcome,context FROM app_attest_evidence
	 WHERE key_id=$1 ORDER BY received_at DESC,id DESC LIMIT $2
	) recent WHERE action='assertion' AND outcome='verified'
	 ORDER BY received_at DESC,id DESC LIMIT 1`, keyID, store.AppAttestDiagnosticLookback).Scan(&result.BootTime, &result.ProcessStartedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &result, nil
}
