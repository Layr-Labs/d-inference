package store

// Postgres implementation of the base-rewards store methods (design §8).
// The money source-of-truth lives here: organic-earnings sums, the idempotent
// per-epoch floor-draw settlement, the floor-draw pool accounting, and the
// session-overlap read used for uptime.

import (
	"context"
	"errors"
	"fmt"
	"hash/fnv"
	"time"
)

// SumProviderEarningsByKey returns total organic micro-USD for one provider node
// in [since, until): amount>0, excluding base_reward credits.
func (s *PostgresStore) SumProviderEarningsByKey(ctx context.Context, providerKey string, since, until time.Time) (int64, error) {
	var total int64
	err := s.pool.QueryRow(ctx,
		`SELECT COALESCE(SUM(amount_micro_usd), 0)
		   FROM provider_earnings
		  WHERE provider_key = $1
		    AND created_at >= $2 AND created_at < $3
		    AND amount_micro_usd > 0
		    AND model <> 'base_reward'`,
		providerKey, since, until,
	).Scan(&total)
	if err != nil {
		return 0, fmt.Errorf("store: sum provider earnings by key: %w", err)
	}
	return total, nil
}

// SettleProviderFloorDraw atomically inserts the idempotent draw row and credits
// the account in the same round-trip. The draw INSERT is the gate: ON CONFLICT
// (provider_key, epoch_id) DO NOTHING means a re-settle of the same epoch inserts
// nothing and credits nothing. A zero-amount draw still records the audit row (so
// it is "settled, $0") but the credit/ledger CTEs (guarded by amount > 0) are
// no-ops. Returns credited=true when this call inserted the row.
func (s *PostgresStore) SettleProviderFloorDraw(ctx context.Context, draw *ProviderFloorDraw) (bool, error) {
	if draw == nil {
		return false, errors.New("provider floor draw is required")
	}
	if draw.ProviderKey == "" {
		return false, errors.New("provider floor draw provider_key is required")
	}
	if draw.EpochID == "" {
		return false, errors.New("provider floor draw epoch_id is required")
	}

	// Earnings row job_id: deterministic per (epoch, provider) so it is idempotent
	// and matches the floor-draw dedup key. Model "base_reward" makes it visible
	// in the provider's earnings history/summary while organic-earnings filters
	// keep it out of draw math.
	earningJobID := "floor:" + draw.EpochID + ":" + draw.ProviderKey

	var credited bool
	err := s.pool.QueryRow(ctx, `
		WITH draw AS (
			INSERT INTO provider_floor_draws (provider_key, account_id, epoch_id, amount_micro_usd,
				floor_micro_usd, earned_micro_usd, uptime_frac, memory_gb, created_at)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8, NOW())
			ON CONFLICT (provider_key, epoch_id) DO NOTHING
			RETURNING account_id, amount_micro_usd
		), credit AS (
			INSERT INTO balances (account_id, balance_micro_usd, withdrawable_micro_usd, updated_at)
			SELECT account_id, amount_micro_usd, amount_micro_usd, NOW() FROM draw WHERE amount_micro_usd > 0
			ON CONFLICT (account_id) DO UPDATE SET
			  balance_micro_usd = balances.balance_micro_usd + EXCLUDED.balance_micro_usd,
			  withdrawable_micro_usd = balances.withdrawable_micro_usd + EXCLUDED.withdrawable_micro_usd,
			  updated_at = NOW()
			RETURNING balance_micro_usd
		), ledger AS (
			INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference, created_at)
			SELECT d.account_id, $9, d.amount_micro_usd, c.balance_micro_usd, $3, NOW()
			FROM draw d CROSS JOIN credit c WHERE d.amount_micro_usd > 0
		), earning AS (
			INSERT INTO provider_earnings (account_id, provider_id, provider_key, job_id, model,
				amount_micro_usd, prompt_tokens, completion_tokens, created_at)
			SELECT d.account_id, '', $1, $10, 'base_reward', d.amount_micro_usd, 0, 0, NOW()
			FROM draw d WHERE d.amount_micro_usd > 0
			ON CONFLICT (job_id) WHERE job_id <> '' DO NOTHING
			RETURNING account_id, provider_key, amount_micro_usd
		), summary_account AS (
			INSERT INTO earnings_summary (key, key_type, total_count, total_micro_usd, total_prompt_tokens, total_completion_tokens, updated_at)
			SELECT account_id, 'account', 0, amount_micro_usd, 0, 0, NOW() FROM earning
			ON CONFLICT (key, key_type) DO UPDATE SET
			  total_micro_usd = earnings_summary.total_micro_usd + EXCLUDED.total_micro_usd,
			  updated_at = NOW()
		), summary_provider AS (
			INSERT INTO earnings_summary (key, key_type, total_count, total_micro_usd, total_prompt_tokens, total_completion_tokens, updated_at)
			SELECT provider_key, 'provider', 0, amount_micro_usd, 0, 0, NOW() FROM earning WHERE provider_key <> ''
			ON CONFLICT (key, key_type) DO UPDATE SET
			  total_micro_usd = earnings_summary.total_micro_usd + EXCLUDED.total_micro_usd,
			  updated_at = NOW()
		)
		SELECT EXISTS (SELECT 1 FROM draw)`,
		draw.ProviderKey,        // $1
		draw.AccountID,          // $2
		draw.EpochID,            // $3
		draw.AmountMicroUSD,     // $4
		draw.FloorMicroUSD,      // $5
		draw.EarnedMicroUSD,     // $6
		draw.UptimeFrac,         // $7
		draw.MemoryGB,           // $8
		string(LedgerFloorDraw), // $9
		earningJobID,            // $10
	).Scan(&credited)
	if err != nil {
		return false, fmt.Errorf("store: settle provider floor draw: %w", err)
	}
	return credited, nil
}

// SumFloorDrawsForEpoch returns Σ amount_micro_usd settled for an epoch.
func (s *PostgresStore) SumFloorDrawsForEpoch(ctx context.Context, epochID string) (int64, error) {
	var total int64
	err := s.pool.QueryRow(ctx,
		`SELECT COALESCE(SUM(amount_micro_usd), 0) FROM provider_floor_draws WHERE epoch_id = $1`,
		epochID,
	).Scan(&total)
	if err != nil {
		return 0, fmt.Errorf("store: sum floor draws for epoch: %w", err)
	}
	return total, nil
}

// ListFloorDrawsForEpoch returns all draw rows for an epoch, largest first.
func (s *PostgresStore) ListFloorDrawsForEpoch(ctx context.Context, epochID string) ([]ProviderFloorDraw, error) {
	rows, err := s.pool.Query(ctx,
		`SELECT id, provider_key, account_id, epoch_id, amount_micro_usd,
		        floor_micro_usd, earned_micro_usd, uptime_frac, memory_gb, created_at
		   FROM provider_floor_draws
		  WHERE epoch_id = $1
		  ORDER BY amount_micro_usd DESC`,
		epochID,
	)
	if err != nil {
		return nil, fmt.Errorf("store: list floor draws for epoch: %w", err)
	}
	defer rows.Close()

	out := []ProviderFloorDraw{}
	for rows.Next() {
		var d ProviderFloorDraw
		if err := rows.Scan(&d.ID, &d.ProviderKey, &d.AccountID, &d.EpochID, &d.AmountMicroUSD,
			&d.FloorMicroUSD, &d.EarnedMicroUSD, &d.UptimeFrac, &d.MemoryGB, &d.CreatedAt); err != nil {
			continue
		}
		out = append(out, d)
	}
	return out, nil
}

// ListProviderSessionsOverlapping returns sessions whose lifetime interval
// overlaps [start, end). Closed sessions end at disconnected_at; open sessions
// may overlap via last_seen + openSessionGrace.
func (s *PostgresStore) ListProviderSessionsOverlapping(ctx context.Context, start, end time.Time, openSessionGrace time.Duration) ([]ProviderSession, error) {
	openGraceStart := start.Add(-openSessionGrace)
	rows, err := s.pool.Query(ctx,
		`SELECT id, session_id, provider_key, serial_number, account_id,
		        connected_at, last_seen, disconnected_at, disconnect_reason
		   FROM provider_sessions
		  WHERE connected_at < $2
		    AND (
		      (disconnected_at IS NOT NULL AND disconnected_at >= $1)
		      OR (disconnected_at IS NULL AND last_seen >= $3)
		    )
		  ORDER BY serial_number, connected_at`,
		start, end, openGraceStart,
	)
	if err != nil {
		return nil, fmt.Errorf("store: list provider sessions overlapping: %w", err)
	}
	defer rows.Close()

	out := []ProviderSession{}
	for rows.Next() {
		var ps ProviderSession
		if err := rows.Scan(&ps.ID, &ps.SessionID, &ps.ProviderKey, &ps.SerialNumber, &ps.AccountID,
			&ps.ConnectedAt, &ps.LastSeen, &ps.DisconnectedAt, &ps.DisconnectReason); err != nil {
			continue
		}
		out = append(out, ps)
	}
	return out, nil
}

// WithEpochSettlementLock holds a session-level Postgres advisory lock keyed on
// epochID for the duration of fn, so concurrent coordinator instances serialize
// epoch settlement and cannot collectively overshoot the floor pool cap. The
// lock is held on a dedicated pooled connection; fn issues its own queries on
// other pool connections.
func (s *PostgresStore) WithEpochSettlementLock(ctx context.Context, epochID string, fn func() error) error {
	conn, err := s.pool.Acquire(ctx)
	if err != nil {
		return fmt.Errorf("store: acquire conn for epoch lock: %w", err)
	}
	defer conn.Release()

	key := epochLockKey(epochID)
	if _, err := conn.Exec(ctx, "SELECT pg_advisory_lock($1)", key); err != nil {
		return fmt.Errorf("store: acquire epoch advisory lock: %w", err)
	}
	defer func() {
		// Release on a fresh context so a cancelled ctx still unlocks the session.
		_, _ = conn.Exec(context.Background(), "SELECT pg_advisory_unlock($1)", key)
	}()

	return fn()
}

// epochLockKey derives a stable, non-negative 63-bit advisory-lock key from a
// namespace prefix + the epoch id (FNV-1a) so the lock is specific to
// base-rewards epoch settlement and never collides with other advisory locks.
func epochLockKey(epochID string) int64 {
	h := fnv.New64a()
	_, _ = h.Write([]byte("base_rewards_epoch:" + epochID))
	return int64(h.Sum64() >> 1)
}
