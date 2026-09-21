package store

import (
	"context"
	"encoding/json"
	"errors"
	"time"
)

// AppAttestReadinessBatchStore supports bounded refreshes of live credential
// state. Each call is one snapshot; an omitted key is unknown, not unrevoked.
// Serving callers must bound the snapshot's lifetime and fence local revocations
// immediately rather than treating successful reads as permanent authorization.
type AppAttestReadinessBatchStore interface {
	GetAppAttestReadinessBatch(context.Context, []string) (map[string]AppAttestReadiness, error)
}

const AppAttestReadinessBatchLimit = 1000

func readinessBatchKeys(keys []string) ([]string, error) {
	seen := make(map[string]struct{})
	unique := make([]string, 0)
	for _, key := range keys {
		if key == "" {
			continue
		}
		if _, ok := seen[key]; ok {
			continue
		}
		if len(unique) == AppAttestReadinessBatchLimit {
			return nil, errors.New("app_attest_readiness_batch_too_large")
		}
		seen[key] = struct{}{}
		unique = append(unique, key)
	}
	return unique, nil
}

func (s *PostgresStore) GetAppAttestReadinessBatch(ctx context.Context, keys []string) (map[string]AppAttestReadiness, error) {
	keys, err := readinessBatchKeys(keys)
	if err != nil {
		return nil, err
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	out := make(map[string]AppAttestReadiness, len(keys))
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
		var r AppAttestReadiness
		var raw []byte
		if err = rows.Scan(&key, &r.Revoked, &raw); err != nil {
			return nil, err
		}
		if len(raw) > 0 {
			r.Receipt = &AppAttestReceipt{}
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

func (s *MemoryStore) GetAppAttestReadinessBatch(ctx context.Context, keys []string) (map[string]AppAttestReadiness, error) {
	keys, err := readinessBatchKeys(keys)
	if err != nil {
		return nil, err
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make(map[string]AppAttestReadiness, len(keys))
	for _, key := range keys {
		if _, exists := s.appAttestShadowKeys[key]; exists {
			out[key] = AppAttestReadiness{Revoked: s.appAttestRevocations[key]}
		}
	}
	for _, evidence := range s.appAttestEvidence {
		receipt := evidence.Decision.Receipt
		if receipt == nil || receipt.Outcome != "verified" {
			continue
		}
		current, exists := out[receipt.KeyID]
		if !exists || current.Receipt != nil && (current.Receipt.ReceivedAt.After(receipt.ReceivedAt) || current.Receipt.ReceivedAt.Equal(receipt.ReceivedAt) && current.Receipt.ID >= receipt.ID) {
			continue
		}
		// Match the PostgreSQL projection; evidence bodies are not needed in the
		// serving snapshot and remain in the private evidence archive.
		current.Receipt = &AppAttestReceipt{ID: receipt.ID, KeyID: receipt.KeyID, Outcome: receipt.Outcome,
			Details: append(json.RawMessage(nil), receipt.Details...), ReceivedAt: receipt.ReceivedAt,
			ExpiresAt: receipt.ExpiresAt, NextAt: receipt.NextAt}
		out[receipt.KeyID] = current
	}
	return out, nil
}

var (
	_ AppAttestReadinessBatchStore = (*PostgresStore)(nil)
	_ AppAttestReadinessBatchStore = (*MemoryStore)(nil)
)
