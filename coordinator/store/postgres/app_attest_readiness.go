package postgres

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

func (s *Store) GetAppAttestReadiness(ctx context.Context, key string) (contracts.AppAttestReadiness, error) {
	var result contracts.AppAttestReadiness
	// Read revocation and receipt in one snapshot. A failed query is unknown,
	// never an implicit non-revoked credential or a zero fraud count.
	var raw []byte
	err := s.pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM app_attest_key_revocations WHERE key_id=$1),
	 (SELECT jsonb_build_object('id',id,'outcome',outcome,'details',details,'received_at',received_at,'expires_at',expires_at,'next_at',next_at)
	 FROM app_attest_receipts WHERE key_id=$1 AND outcome='verified' ORDER BY received_at DESC,id DESC LIMIT 1)`, key).Scan(&result.Revoked, &raw)
	if err == nil && len(raw) > 0 {
		result.Receipt = &contracts.AppAttestReceipt{}
		err = json.Unmarshal(raw, result.Receipt)
	}
	return result, err
}

func (s *Store) RevokeAppAttestKey(ctx context.Context, key, account, reason string) (bool, error) {
	if account == "" || reason == "" || len(reason) > 128 {
		return false, errors.New("invalid_revocation")
	}
	tag, err := s.pool.Exec(ctx, `INSERT INTO app_attest_key_revocations(key_id,account_id,reason)
	 SELECT key_id,$2,$3 FROM app_attest_shadow_keys WHERE key_id=$1 AND evidence->>'account_id'=$2
	 ON CONFLICT(key_id) DO NOTHING`, key, account, reason)
	return tag.RowsAffected() == 1, err
}

// Keep the compile-time storage contract explicit for decorated stores.
var _ contracts.AppAttestReadinessStore = (*Store)(nil)
