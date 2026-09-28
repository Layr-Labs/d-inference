package store

import (
	"context"
	"fmt"
	"strings"
	"time"
)

// cacheRoutingHoldersDDL and cacheRoutingDemandDDL are the durable copies of
// the registry's in-memory holder and demand indexes (see
// cache_routing_state.go). Keys and anchors are chained block hashes, never
// prompt content. The primary key is (key, cache_epoch): a holder key names a
// boundary, an epoch names one provider's SSD root, and a boundary is held by
// at most the configured number of providers.
const cacheRoutingHoldersDDL = `CREATE TABLE IF NOT EXISTS cache_routing_holders (
 key TEXT NOT NULL,
 cache_epoch TEXT NOT NULL,
 tier TEXT NOT NULL DEFAULT '',
 model_id TEXT NOT NULL,
 model_aggregate_hash TEXT NOT NULL DEFAULT '',
 prompt_contract_id TEXT NOT NULL DEFAULT '',
 block_hash_version TEXT NOT NULL DEFAULT '',
 anchor_chain_hash TEXT NOT NULL DEFAULT '',
 anchor_token_count INTEGER NOT NULL DEFAULT 0,
 required_recompute_tokens INTEGER NOT NULL DEFAULT 0,
 stage_ms DOUBLE PRECISION NOT NULL DEFAULT 0,
 updated_at TIMESTAMPTZ NOT NULL,
 expires_at TIMESTAMPTZ NOT NULL,
 PRIMARY KEY (key, cache_epoch)
)`

const cacheRoutingHoldersExpiryIndexDDL = `CREATE INDEX IF NOT EXISTS idx_cache_routing_holders_expires ON cache_routing_holders(expires_at)`

const cacheRoutingDemandDDL = `CREATE TABLE IF NOT EXISTS cache_routing_demand (
 key TEXT PRIMARY KEY,
 seen_at TIMESTAMPTZ NOT NULL
)`

const cacheRoutingDemandSeenIndexDDL = `CREATE INDEX IF NOT EXISTS idx_cache_routing_demand_seen ON cache_routing_demand(seen_at)`

const cacheHolderInsertColumns = 13

func (s *PostgresStore) UpsertCacheHolders(ctx context.Context, records []CacheHolderRecord) error {
	for _, r := range records {
		if err := r.validate(); err != nil {
			return err
		}
	}
	for start := 0; start < len(records); start += CacheRoutingStateBatchRows {
		end := min(start+CacheRoutingStateBatchRows, len(records))
		chunk := records[start:end]
		var sb strings.Builder
		sb.WriteString(`INSERT INTO cache_routing_holders (key, cache_epoch, tier, model_id, model_aggregate_hash, prompt_contract_id, block_hash_version, anchor_chain_hash, anchor_token_count, required_recompute_tokens, stage_ms, updated_at, expires_at) VALUES `)
		args := make([]any, 0, len(chunk)*cacheHolderInsertColumns)
		for i, r := range chunk {
			if i > 0 {
				sb.WriteString(",")
			}
			base := i * cacheHolderInsertColumns
			sb.WriteString("(")
			for c := 1; c <= cacheHolderInsertColumns; c++ {
				if c > 1 {
					sb.WriteString(",")
				}
				fmt.Fprintf(&sb, "$%d", base+c)
			}
			sb.WriteString(")")
			args = append(args, r.Key, r.CacheEpoch, r.Tier, r.ModelID, r.ModelAggregateHash, r.PromptContractID,
				r.BlockHashVersion, r.AnchorChainHash, r.AnchorTokenCount, r.RequiredRecomputeTokens, r.StageMs,
				r.UpdatedAt.UTC(), r.ExpiresAt.UTC())
		}
		// The newer receipt wins every descriptive column; expiry never moves
		// backwards, so a replayed or reordered batch is idempotent.
		sb.WriteString(` ON CONFLICT (key, cache_epoch) DO UPDATE SET
 tier = CASE WHEN EXCLUDED.updated_at >= cache_routing_holders.updated_at THEN EXCLUDED.tier ELSE cache_routing_holders.tier END,
 model_id = CASE WHEN EXCLUDED.updated_at >= cache_routing_holders.updated_at THEN EXCLUDED.model_id ELSE cache_routing_holders.model_id END,
 model_aggregate_hash = CASE WHEN EXCLUDED.updated_at >= cache_routing_holders.updated_at THEN EXCLUDED.model_aggregate_hash ELSE cache_routing_holders.model_aggregate_hash END,
 prompt_contract_id = CASE WHEN EXCLUDED.updated_at >= cache_routing_holders.updated_at THEN EXCLUDED.prompt_contract_id ELSE cache_routing_holders.prompt_contract_id END,
 block_hash_version = CASE WHEN EXCLUDED.updated_at >= cache_routing_holders.updated_at THEN EXCLUDED.block_hash_version ELSE cache_routing_holders.block_hash_version END,
 anchor_chain_hash = CASE WHEN EXCLUDED.updated_at >= cache_routing_holders.updated_at THEN EXCLUDED.anchor_chain_hash ELSE cache_routing_holders.anchor_chain_hash END,
 anchor_token_count = CASE WHEN EXCLUDED.updated_at >= cache_routing_holders.updated_at THEN EXCLUDED.anchor_token_count ELSE cache_routing_holders.anchor_token_count END,
 required_recompute_tokens = CASE WHEN EXCLUDED.updated_at >= cache_routing_holders.updated_at THEN EXCLUDED.required_recompute_tokens ELSE cache_routing_holders.required_recompute_tokens END,
 stage_ms = CASE WHEN EXCLUDED.updated_at >= cache_routing_holders.updated_at THEN EXCLUDED.stage_ms ELSE cache_routing_holders.stage_ms END,
 updated_at = GREATEST(EXCLUDED.updated_at, cache_routing_holders.updated_at),
 expires_at = GREATEST(EXCLUDED.expires_at, cache_routing_holders.expires_at)`)
		if _, err := s.pool.Exec(ctx, sb.String(), args...); err != nil {
			return fmt.Errorf("upsert cache holders: %w", err)
		}
	}
	return nil
}

func (s *PostgresStore) DeleteCacheHolders(ctx context.Context, keys []CacheHolderKey) error {
	for start := 0; start < len(keys); start += CacheRoutingStateBatchRows {
		end := min(start+CacheRoutingStateBatchRows, len(keys))
		chunk := keys[start:end]
		ks := make([]string, 0, len(chunk))
		epochs := make([]string, 0, len(chunk))
		for _, k := range chunk {
			ks = append(ks, k.Key)
			epochs = append(epochs, k.CacheEpoch)
		}
		// unnest pairs the two arrays positionally, so one statement deletes
		// exactly the (key, epoch) rows in the chunk.
		_, err := s.pool.Exec(ctx, `DELETE FROM cache_routing_holders h
 USING unnest($1::text[], $2::text[]) AS d(key, cache_epoch)
 WHERE h.key = d.key AND h.cache_epoch = d.cache_epoch`, ks, epochs)
		if err != nil {
			return fmt.Errorf("delete cache holders: %w", err)
		}
	}
	return nil
}

func (s *PostgresStore) LoadCacheHolders(ctx context.Context, now time.Time) ([]CacheHolderRecord, error) {
	rows, err := s.pool.Query(ctx, `SELECT key, cache_epoch, tier, model_id, model_aggregate_hash, prompt_contract_id,
 block_hash_version, anchor_chain_hash, anchor_token_count, required_recompute_tokens, stage_ms, updated_at, expires_at
 FROM cache_routing_holders WHERE expires_at > $1`, now.UTC())
	if err != nil {
		return nil, fmt.Errorf("load cache holders: %w", err)
	}
	defer rows.Close()
	out := []CacheHolderRecord{}
	for rows.Next() {
		var r CacheHolderRecord
		if err := rows.Scan(&r.Key, &r.CacheEpoch, &r.Tier, &r.ModelID, &r.ModelAggregateHash, &r.PromptContractID,
			&r.BlockHashVersion, &r.AnchorChainHash, &r.AnchorTokenCount, &r.RequiredRecomputeTokens, &r.StageMs,
			&r.UpdatedAt, &r.ExpiresAt); err != nil {
			return nil, fmt.Errorf("scan cache holder: %w", err)
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

func (s *PostgresStore) UpsertCacheDemand(ctx context.Context, records []CacheDemandRecord) error {
	for _, r := range records {
		if err := r.validate(); err != nil {
			return err
		}
	}
	for start := 0; start < len(records); start += CacheRoutingStateBatchRows {
		end := min(start+CacheRoutingStateBatchRows, len(records))
		chunk := records[start:end]
		keys := make([]string, 0, len(chunk))
		seen := make([]time.Time, 0, len(chunk))
		for _, r := range chunk {
			keys = append(keys, r.Key)
			seen = append(seen, r.SeenAt.UTC())
		}
		_, err := s.pool.Exec(ctx, `INSERT INTO cache_routing_demand (key, seen_at)
 SELECT d.key, d.seen_at FROM unnest($1::text[], $2::timestamptz[]) AS d(key, seen_at)
 ON CONFLICT (key) DO UPDATE SET seen_at = GREATEST(EXCLUDED.seen_at, cache_routing_demand.seen_at)`, keys, seen)
		if err != nil {
			return fmt.Errorf("upsert cache demand: %w", err)
		}
	}
	return nil
}

func (s *PostgresStore) LoadCacheDemand(ctx context.Context, notBefore time.Time) ([]CacheDemandRecord, error) {
	rows, err := s.pool.Query(ctx, `SELECT key, seen_at FROM cache_routing_demand WHERE seen_at >= $1`, notBefore.UTC())
	if err != nil {
		return nil, fmt.Errorf("load cache demand: %w", err)
	}
	defer rows.Close()
	out := []CacheDemandRecord{}
	for rows.Next() {
		var r CacheDemandRecord
		if err := rows.Scan(&r.Key, &r.SeenAt); err != nil {
			return nil, fmt.Errorf("scan cache demand: %w", err)
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// PruneCacheRoutingState deletes in bounded batches so a 250k-row table never
// holds a long lock; each loop iteration is its own short statement.
func (s *PostgresStore) PruneCacheRoutingState(ctx context.Context, now, demandNotBefore time.Time) (int64, error) {
	var total int64
	for {
		tag, err := s.pool.Exec(ctx, `DELETE FROM cache_routing_holders WHERE ctid IN (
 SELECT ctid FROM cache_routing_holders WHERE expires_at <= $1 LIMIT $2)`, now.UTC(), cacheRoutingPruneBatchRows)
		if err != nil {
			return total, fmt.Errorf("prune cache holders: %w", err)
		}
		total += tag.RowsAffected()
		if tag.RowsAffected() < cacheRoutingPruneBatchRows {
			break
		}
	}
	for {
		tag, err := s.pool.Exec(ctx, `DELETE FROM cache_routing_demand WHERE ctid IN (
 SELECT ctid FROM cache_routing_demand WHERE seen_at < $1 LIMIT $2)`, demandNotBefore.UTC(), cacheRoutingPruneBatchRows)
		if err != nil {
			return total, fmt.Errorf("prune cache demand: %w", err)
		}
		total += tag.RowsAffected()
		if tag.RowsAffected() < cacheRoutingPruneBatchRows {
			break
		}
	}
	return total, nil
}
