package store

import (
	"context"
	"encoding/json"
	"errors"
	"time"
)

type AppAttestReadiness struct {
	Revoked bool
	Receipt *AppAttestReceipt
}

type AppAttestReadinessStore interface {
	GetAppAttestReadiness(context.Context, string) (AppAttestReadiness, error)
	RevokeAppAttestKey(context.Context, string, string, string) (bool, error)
}

const appAttestRevocationDDL = `CREATE TABLE IF NOT EXISTS app_attest_key_revocations (
 key_id TEXT PRIMARY KEY REFERENCES app_attest_shadow_keys(key_id),
 account_id TEXT NOT NULL, reason TEXT NOT NULL, revoked_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
)`

func (s *PostgresStore) GetAppAttestReadiness(ctx context.Context, key string) (AppAttestReadiness, error) {
	var result AppAttestReadiness
	// Read revocation and receipt in one snapshot. A failed query is unknown,
	// never an implicit non-revoked credential or a zero fraud count.
	var raw []byte
	err := s.pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM app_attest_key_revocations WHERE key_id=$1),
	 (SELECT jsonb_build_object('id',id,'outcome',outcome,'details',details,'received_at',received_at,'expires_at',expires_at,'next_at',next_at)
	 FROM app_attest_receipts WHERE key_id=$1 AND outcome='verified' ORDER BY received_at DESC,id DESC LIMIT 1)`, key).Scan(&result.Revoked, &raw)
	if err == nil && len(raw) > 0 {
		result.Receipt = &AppAttestReceipt{}
		err = json.Unmarshal(raw, result.Receipt)
	}
	return result, err
}

func (s *PostgresStore) RevokeAppAttestKey(ctx context.Context, key, account, reason string) (bool, error) {
	if account == "" || reason == "" || len(reason) > 128 {
		return false, errors.New("invalid_revocation")
	}
	tag, err := s.pool.Exec(ctx, `INSERT INTO app_attest_key_revocations(key_id,account_id,reason)
	 SELECT key_id,$2,$3 FROM app_attest_shadow_keys WHERE key_id=$1 AND evidence->>'account_id'=$2
	 ON CONFLICT(key_id) DO NOTHING`, key, account, reason)
	return tag.RowsAffected() == 1, err
}

func (s *MemoryStore) GetAppAttestReadiness(ctx context.Context, key string) (AppAttestReadiness, error) {
	if err := ctx.Err(); err != nil {
		return AppAttestReadiness{}, err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	r := AppAttestReadiness{Revoked: s.appAttestRevocations[key]}
	var latest time.Time
	for _, e := range s.appAttestEvidence {
		if receipt := e.Decision.Receipt; receipt != nil && receipt.KeyID == key && receipt.Outcome == "verified" && receipt.ReceivedAt.After(latest) {
			copy := *receipt
			copy.Details = append(json.RawMessage(nil), receipt.Details...)
			r.Receipt = &copy
			latest = receipt.ReceivedAt
		}
	}
	return r, nil
}

func (s *MemoryStore) RevokeAppAttestKey(ctx context.Context, key, account, reason string) (bool, error) {
	if err := ctx.Err(); err != nil {
		return false, err
	}
	if account == "" || reason == "" || len(reason) > 128 {
		return false, errors.New("invalid_revocation")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	k, ok := s.appAttestShadowKeys[key]
	if !ok || k.AccountID != account || s.appAttestRevocations[key] {
		return false, nil
	}
	if s.appAttestRevocations == nil {
		s.appAttestRevocations = map[string]bool{}
	}
	s.appAttestRevocations[key] = true
	return true, nil
}

// Keep the compile-time storage contract explicit for decorated stores.
var _ AppAttestReadinessStore = (*PostgresStore)(nil)
