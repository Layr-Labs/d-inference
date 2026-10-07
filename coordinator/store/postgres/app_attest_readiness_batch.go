package postgres

import (
	"context"
	"encoding/json"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/store/shared"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *PostgresStore) GetAppAttestReadinessBatch(ctx context.Context, keys []string) (map[string]store.AppAttestReadiness, error) {
	keys, err := shared.ReadinessBatchKeys(keys)
	if err != nil {
		return nil, err
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	out := make(map[string]store.AppAttestReadiness, len(keys))
	if len(keys) == 0 {
		return out, nil
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	rows, err := s.pool.Query(ctx, `SELECT k.key_id,r.key_id IS NOT NULL,
	 (SELECT jsonb_build_object('id',id,'key_id',key_id,'outcome',outcome,'details',details,'received_at',received_at,'expires_at',expires_at,'next_at',next_at)
	 FROM app_attest_receipts WHERE key_id=k.key_id AND outcome='verified' ORDER BY received_at DESC,id DESC LIMIT 1)
	 FROM app_attest_shadow_keys k LEFT JOIN app_attest_key_revocations r ON r.key_id=k.key_id
	 WHERE k.key_id=ANY($1::text[])`, keys)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var key string
		var r store.AppAttestReadiness
		var raw []byte
		if err = rows.Scan(&key, &r.Revoked, &raw); err != nil {
			return nil, err
		}
		if len(raw) > 0 {
			r.Receipt = &store.AppAttestReceipt{}
			if err = json.Unmarshal(raw, r.Receipt); err != nil {
				return nil, err
			}
		}
		out[key] = r
	}
	if err = rows.Err(); err != nil {
		return nil, err
	}
	return out, nil
}

var _ store.AppAttestReadinessBatchStore = (*PostgresStore)(nil)
