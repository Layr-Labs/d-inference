package postgres

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/jackc/pgx/v5"
)

const appAttestShadowDDL = `CREATE TABLE IF NOT EXISTS app_attest_shadow_keys (
	key_id TEXT PRIMARY KEY, owner TEXT NOT NULL, evidence JSONB NOT NULL,
	counter BIGINT NOT NULL DEFAULT 0 CHECK (counter >= 0 AND counter <= 4294967295),
	created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
)`

func (s *PostgresStore) GetAppAttestShadowKey(ctx context.Context, id string) (*store.AppAttestShadowKey, error) {
	var data []byte
	var counter uint32
	var updated time.Time
	err := s.pool.QueryRow(ctx, `SELECT evidence,counter,updated_at FROM app_attest_shadow_keys WHERE key_id=$1`, id).Scan(&data, &counter, &updated)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var record store.AppAttestShadowKey
	if err := json.Unmarshal(data, &record); err != nil {
		return nil, err
	}
	record.Counter = counter
	record.UpdatedAt = updated
	return &record, nil
}

func (s *PostgresStore) InsertAppAttestShadowKey(ctx context.Context, key store.AppAttestShadowKey) (bool, error) {
	data, err := json.Marshal(key)
	if err != nil {
		return false, err
	}
	tag, err := s.pool.Exec(ctx, `INSERT INTO app_attest_shadow_keys (key_id,owner,evidence) VALUES ($1,$2,$3) ON CONFLICT DO NOTHING`, key.KeyID, key.Owner, data)
	return tag.RowsAffected() == 1, err
}

func (s *PostgresStore) AdvanceAppAttestShadowCounter(ctx context.Context, id, owner string, counter uint32) (bool, error) {
	tag, err := s.pool.Exec(ctx, `UPDATE app_attest_shadow_keys SET counter=$3,updated_at=$4 WHERE key_id=$1 AND owner=$2 AND counter<$3`, id, owner, counter, time.Now())
	return tag.RowsAffected() == 1, err
}
