package postgres

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"github.com/jackc/pgx/v5"
)

func (s *Store) GetAppAttestShadowKey(ctx context.Context, id string) (*contracts.AppAttestShadowKey, error) {
	var data []byte
	var counter uint32
	err := s.pool.QueryRow(ctx, `SELECT evidence,counter FROM app_attest_shadow_keys WHERE key_id=$1`, id).Scan(&data, &counter)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var record contracts.AppAttestShadowKey
	if err := json.Unmarshal(data, &record); err != nil {
		return nil, err
	}
	record.Counter = counter
	return &record, nil
}

func (s *Store) InsertAppAttestShadowKey(ctx context.Context, key contracts.AppAttestShadowKey) (bool, error) {
	data, err := json.Marshal(key)
	if err != nil {
		return false, err
	}
	tag, err := s.pool.Exec(ctx, `INSERT INTO app_attest_shadow_keys (key_id,owner,evidence) VALUES ($1,$2,$3) ON CONFLICT DO NOTHING`, key.KeyID, key.Owner, data)
	return tag.RowsAffected() == 1, err
}

func (s *Store) AdvanceAppAttestShadowCounter(ctx context.Context, id, owner string, counter uint32) (bool, error) {
	tag, err := s.pool.Exec(ctx, `UPDATE app_attest_shadow_keys SET counter=$3,updated_at=$4 WHERE key_id=$1 AND owner=$2 AND counter<$3`, id, owner, counter, time.Now())
	return tag.RowsAffected() == 1, err
}
