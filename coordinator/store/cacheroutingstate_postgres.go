package store

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

// cacheRoutingHoldersDDL and cacheRoutingDemandDDL are the durable copies of
// the registry's in-memory holder and demand indexes (see
// cacheroutingstate/records.go). Keys are HMACs under the route key; the
// provider-confirmed chain hash is not stored (cacheRoutingHoldersDropChainHashDDL
// removes the column earlier builds of this branch created), and no prompt
// content is. The primary key is (key, cache_epoch): a holder key names a
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
 ready_boundary_mode TEXT NOT NULL DEFAULT '',
 anchor_token_count INTEGER NOT NULL DEFAULT 0,
 required_recompute_tokens INTEGER NOT NULL DEFAULT 0,
 stage_ms DOUBLE PRECISION NOT NULL DEFAULT 0,
 measured_stage_ms DOUBLE PRECISION NOT NULL DEFAULT 0,
 measured_expires_at TIMESTAMPTZ,
 updated_at TIMESTAMPTZ NOT NULL,
 expires_at TIMESTAMPTZ NOT NULL,
 PRIMARY KEY (key, cache_epoch)
)`

// The chain hash column of earlier builds is dropped, and its values with it.
const cacheRoutingHoldersDropChainHashDDL = `ALTER TABLE cache_routing_holders DROP COLUMN IF EXISTS anchor_chain_hash`

// Tables created by earlier builds of this branch pick up the columns added
// since; each ADD is a no-op once present.
const cacheRoutingHoldersBackfillColumnsDDL = `ALTER TABLE cache_routing_holders
 ADD COLUMN IF NOT EXISTS measured_stage_ms DOUBLE PRECISION NOT NULL DEFAULT 0,
 ADD COLUMN IF NOT EXISTS measured_expires_at TIMESTAMPTZ,
 ADD COLUMN IF NOT EXISTS ready_boundary_mode TEXT NOT NULL DEFAULT ''`

// The prune deletes rows whose effective expiry under the active TTL has
// passed, written as `expires_at <= now OR updated_at <= now - ttl` so both
// halves are index-served (a bitmap OR over the two indexes) instead of a
// full scan every five minutes; a boot-time load orders by the clamped
// expression and scans the table once.
const cacheRoutingHoldersExpiryIndexDDL = `CREATE INDEX IF NOT EXISTS idx_cache_routing_holders_expires ON cache_routing_holders(expires_at)`

const cacheRoutingHoldersUpdatedIndexDDL = `CREATE INDEX IF NOT EXISTS idx_cache_routing_holders_updated ON cache_routing_holders(updated_at)`

const cacheRoutingDemandDDL = `CREATE TABLE IF NOT EXISTS cache_routing_demand (
 key TEXT PRIMARY KEY,
 seen_at TIMESTAMPTZ NOT NULL
)`

const cacheRoutingDemandSeenIndexDDL = `CREATE INDEX IF NOT EXISTS idx_cache_routing_demand_seen ON cache_routing_demand(seen_at)`

// cacheRoutingMetaDDL records the derived cache-key generation the rows were
// written under (a non-secret fingerprint), so a master-key rotation resets
// the tables instead of restoring rows no request can ever match.
const cacheRoutingMetaDDL = `CREATE TABLE IF NOT EXISTS cache_routing_meta (
 name TEXT PRIMARY KEY,
 value TEXT NOT NULL,
 updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
)`

const cacheRoutingKeyFingerprintName = "key_fingerprint"

const cacheHolderInsertColumns = 15

func (s *PostgresStore) UpsertCacheHolders(ctx context.Context, records []crs.HolderRecord) error {
	for _, r := range records {
		if err := r.Validate(); err != nil {
			return err
		}
	}
	records = crs.DedupeHolders(records)
	for start := 0; start < len(records); start += crs.BatchRows {
		end := min(start+crs.BatchRows, len(records))
		chunk := records[start:end]
		var sb strings.Builder
		sb.WriteString(`INSERT INTO cache_routing_holders (key, cache_epoch, tier, model_id, model_aggregate_hash, prompt_contract_id, block_hash_version, ready_boundary_mode, anchor_token_count, required_recompute_tokens, stage_ms, measured_stage_ms, measured_expires_at, updated_at, expires_at) VALUES `)
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
				r.BlockHashVersion, r.ReadyBoundaryMode, r.AnchorTokenCount, r.RequiredRecomputeTokens, r.StageMs,
				r.MeasuredStageMs, nullableTime(r.MeasuredExpiresAt), r.UpdatedAt.UTC(), r.ExpiresAt.UTC())
		}
		// The newer receipt wins every descriptive column; expiry never moves
		// backwards, so a replayed or reordered batch is idempotent.
		sb.WriteString(` ON CONFLICT (key, cache_epoch) DO UPDATE SET
 tier = CASE WHEN EXCLUDED.updated_at >= cache_routing_holders.updated_at THEN EXCLUDED.tier ELSE cache_routing_holders.tier END,
 model_id = CASE WHEN EXCLUDED.updated_at >= cache_routing_holders.updated_at THEN EXCLUDED.model_id ELSE cache_routing_holders.model_id END,
 model_aggregate_hash = CASE WHEN EXCLUDED.updated_at >= cache_routing_holders.updated_at THEN EXCLUDED.model_aggregate_hash ELSE cache_routing_holders.model_aggregate_hash END,
 prompt_contract_id = CASE WHEN EXCLUDED.updated_at >= cache_routing_holders.updated_at THEN EXCLUDED.prompt_contract_id ELSE cache_routing_holders.prompt_contract_id END,
 block_hash_version = CASE WHEN EXCLUDED.updated_at >= cache_routing_holders.updated_at THEN EXCLUDED.block_hash_version ELSE cache_routing_holders.block_hash_version END,
 ready_boundary_mode = CASE WHEN EXCLUDED.updated_at >= cache_routing_holders.updated_at THEN EXCLUDED.ready_boundary_mode ELSE cache_routing_holders.ready_boundary_mode END,
 anchor_token_count = CASE WHEN EXCLUDED.updated_at >= cache_routing_holders.updated_at THEN EXCLUDED.anchor_token_count ELSE cache_routing_holders.anchor_token_count END,
 required_recompute_tokens = CASE WHEN EXCLUDED.updated_at >= cache_routing_holders.updated_at THEN EXCLUDED.required_recompute_tokens ELSE cache_routing_holders.required_recompute_tokens END,
 stage_ms = CASE WHEN EXCLUDED.updated_at >= cache_routing_holders.updated_at THEN EXCLUDED.stage_ms ELSE cache_routing_holders.stage_ms END,
 measured_stage_ms = CASE WHEN EXCLUDED.updated_at >= cache_routing_holders.updated_at THEN EXCLUDED.measured_stage_ms ELSE cache_routing_holders.measured_stage_ms END,
 measured_expires_at = CASE WHEN EXCLUDED.updated_at >= cache_routing_holders.updated_at THEN EXCLUDED.measured_expires_at ELSE cache_routing_holders.measured_expires_at END,
 updated_at = GREATEST(EXCLUDED.updated_at, cache_routing_holders.updated_at),
 expires_at = GREATEST(EXCLUDED.expires_at, cache_routing_holders.expires_at)`)
		if _, err := s.pool.Exec(ctx, sb.String(), args...); err != nil {
			return fmt.Errorf("upsert cache holders: %w", err)
		}
	}
	return nil
}

func (s *PostgresStore) DeleteCacheHolders(ctx context.Context, keys []crs.HolderKey) error {
	for start := 0; start < len(keys); start += crs.BatchRows {
		end := min(start+crs.BatchRows, len(keys))
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

func (s *PostgresStore) LoadCacheHolders(ctx context.Context, now time.Time, ttl time.Duration, limit int) ([]crs.HolderRecord, error) {
	// The effective expiry applies the current TTL before the filter, the
	// order and the limit, so a capped load after a TTL reduction is over
	// rows that are still valid. Rows updated after now (a previous
	// instance's clock ran ahead) are skipped: they would sort first and be
	// routed as fresh past the TTL. Longest-lived first; a limit of 0 or
	// less loads everything.
	// Rows the prune tolerates (updated at most FutureSkew ahead of now, a
	// previous instance's slight skew) load with their update time clamped
	// to now; rows further ahead are the prune's to remove and stay out.
	expiry := "expires_at"
	args := []any{now.UTC(), now.Add(crs.FutureSkew).UTC()}
	if ttl > 0 {
		expiry = "LEAST(expires_at, updated_at + $3::bigint * interval '1 microsecond')"
		args = append(args, ttl.Microseconds())
	}
	query := fmt.Sprintf(`SELECT key, cache_epoch, tier, model_id, model_aggregate_hash, prompt_contract_id,
 block_hash_version, ready_boundary_mode, anchor_token_count, required_recompute_tokens, stage_ms,
 measured_stage_ms, measured_expires_at, updated_at, effective_expires_at
 FROM (SELECT *, %s AS effective_expires_at FROM cache_routing_holders) h
 WHERE effective_expires_at > $1 AND updated_at <= $2 ORDER BY effective_expires_at DESC, key, cache_epoch`, expiry)
	if limit > 0 {
		query += fmt.Sprintf(` LIMIT $%d`, len(args)+1)
		args = append(args, limit)
	}
	rows, err := s.pool.Query(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("load cache holders: %w", err)
	}
	defer rows.Close()
	out := []crs.HolderRecord{}
	for rows.Next() {
		var (
			r               crs.HolderRecord
			measuredExpires *time.Time
		)
		if err := rows.Scan(&r.Key, &r.CacheEpoch, &r.Tier, &r.ModelID, &r.ModelAggregateHash, &r.PromptContractID,
			&r.BlockHashVersion, &r.ReadyBoundaryMode, &r.AnchorTokenCount, &r.RequiredRecomputeTokens, &r.StageMs,
			&r.MeasuredStageMs, &measuredExpires, &r.UpdatedAt, &r.ExpiresAt); err != nil {
			return nil, fmt.Errorf("scan cache holder: %w", err)
		}
		if measuredExpires != nil {
			r.MeasuredExpiresAt = *measuredExpires
		}
		if r.UpdatedAt.After(now) {
			r.UpdatedAt = now
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

func (s *PostgresStore) UpsertCacheDemand(ctx context.Context, records []crs.DemandRecord) error {
	for _, r := range records {
		if err := r.Validate(); err != nil {
			return err
		}
	}
	records = crs.DedupeDemand(records)
	for start := 0; start < len(records); start += crs.BatchRows {
		end := min(start+crs.BatchRows, len(records))
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

func (s *PostgresStore) LoadCacheDemand(ctx context.Context, notBefore, notAfter time.Time, limit int) ([]crs.DemandRecord, error) {
	// Newest first so a capped restore keeps the freshest keys; rows stamped
	// after notAfter (a previous instance's clock ran ahead) are skipped so
	// they cannot take the cap; a limit of 0 or less loads everything.
	// Rows within the skew tolerance past notAfter load with their seen
	// time clamped to notAfter, as the holder load does.
	query := `SELECT key, seen_at FROM cache_routing_demand WHERE seen_at >= $1 AND seen_at <= $2 ORDER BY seen_at DESC, key`
	args := []any{notBefore.UTC(), notAfter.Add(crs.FutureSkew).UTC()}
	if limit > 0 {
		query += ` LIMIT $3`
		args = append(args, limit)
	}
	rows, err := s.pool.Query(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("load cache demand: %w", err)
	}
	defer rows.Close()
	out := []crs.DemandRecord{}
	for rows.Next() {
		var r crs.DemandRecord
		if err := rows.Scan(&r.Key, &r.SeenAt); err != nil {
			return nil, fmt.Errorf("scan cache demand: %w", err)
		}
		if r.SeenAt.After(notAfter) {
			r.SeenAt = notAfter
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

func (s *PostgresStore) CacheRoutingKeyFingerprint(ctx context.Context) (string, error) {
	var value string
	err := s.pool.QueryRow(ctx, `SELECT value FROM cache_routing_meta WHERE name = $1`, cacheRoutingKeyFingerprintName).Scan(&value)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return "", nil
		}
		return "", fmt.Errorf("load cache routing key fingerprint: %w", err)
	}
	return value, nil
}

// ResetCacheRoutingState empties both tables with unconditional bounded
// deletes (not TRUNCATE, whose exclusive lock a still-draining old container
// could block on, and not an expiry cutoff, which a long TTL could exceed)
// and records the new key generation last, so a crash mid-way leaves the old
// fingerprint and the next boot resets again.
func (s *PostgresStore) ResetCacheRoutingState(ctx context.Context, fingerprint string) error {
	for _, table := range []string{"cache_routing_holders", "cache_routing_demand"} {
		stmt := fmt.Sprintf(`DELETE FROM %s WHERE ctid IN (SELECT ctid FROM %s LIMIT $1)`, table, table)
		for {
			tag, err := s.pool.Exec(ctx, stmt, crs.PruneBatchRows)
			if err != nil {
				return fmt.Errorf("reset %s: %w", table, err)
			}
			if tag.RowsAffected() < crs.PruneBatchRows {
				break
			}
		}
	}
	_, err := s.pool.Exec(ctx, `INSERT INTO cache_routing_meta (name, value, updated_at) VALUES ($1, $2, now())
 ON CONFLICT (name) DO UPDATE SET value = EXCLUDED.value, updated_at = now()`, cacheRoutingKeyFingerprintName, fingerprint)
	if err != nil {
		return fmt.Errorf("store cache routing key fingerprint: %w", err)
	}
	return nil
}

// PruneCacheRoutingState deletes in bounded batches so a 250k-row table never
// holds a long lock; each loop iteration is its own short statement.
func (s *PostgresStore) PruneCacheRoutingState(ctx context.Context, now time.Time, ttl time.Duration, demandNotBefore time.Time) (int64, error) {
	var total int64
	// Equivalent to LEAST(expires_at, updated_at + ttl) <= now, in a form the
	// expires_at and updated_at indexes both serve.
	// A row stamped ahead of the clock by more than FutureSkew is another
	// instance's skew: loads quarantine it, and its future updated_at would
	// outrank every current receipt in the merge, so it is removed.
	expired := `(expires_at <= $1 OR updated_at > $3)`
	args := []any{now.UTC(), crs.PruneBatchRows, now.Add(crs.FutureSkew).UTC()}
	if ttl > 0 {
		expired = `(expires_at <= $1 OR updated_at > $3 OR updated_at <= $4)`
		args = append(args, now.Add(-ttl).UTC())
	}
	for {
		tag, err := s.pool.Exec(ctx, `DELETE FROM cache_routing_holders WHERE ctid IN (
 SELECT ctid FROM cache_routing_holders WHERE `+expired+` LIMIT $2)`, args...)
		if err != nil {
			return total, fmt.Errorf("prune cache holders: %w", err)
		}
		total += tag.RowsAffected()
		if tag.RowsAffected() < crs.PruneBatchRows {
			break
		}
	}
	for {
		tag, err := s.pool.Exec(ctx, `DELETE FROM cache_routing_demand WHERE ctid IN (
 SELECT ctid FROM cache_routing_demand WHERE seen_at < $1 OR seen_at > $3 LIMIT $2)`,
			demandNotBefore.UTC(), crs.PruneBatchRows, now.Add(crs.FutureSkew).UTC())
		if err != nil {
			return total, fmt.Errorf("prune cache demand: %w", err)
		}
		total += tag.RowsAffected()
		if tag.RowsAffected() < crs.PruneBatchRows {
			break
		}
	}
	return total, nil
}

// nullableTime maps the zero time to SQL NULL.
func nullableTime(v time.Time) any {
	if v.IsZero() {
		return nil
	}
	return v.UTC()
}
