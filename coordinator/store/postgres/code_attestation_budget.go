package postgres

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

func (s *Store) ListCodeAttestPushBudgets(ctx context.Context) ([]contracts.CodeAttestPushBudget, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	rows, err := s.pool.Query(ctx,
		`SELECT se_pubkey, token_hash, next_push_at, updated_at, last_clear_at
		   FROM code_attest_push_budgets`)
	if err != nil {
		return nil, fmt.Errorf("store: list code attest push budgets: %w", err)
	}
	defer rows.Close()
	var out []contracts.CodeAttestPushBudget
	for rows.Next() {
		var rec contracts.CodeAttestPushBudget
		var lastClear *time.Time
		if err := rows.Scan(
			&rec.SEPubKey, &rec.TokenHash, &rec.NextPushAt, &rec.UpdatedAt,
			&lastClear,
		); err != nil {
			return nil, fmt.Errorf("store: scan code attest push budget: %w", err)
		}
		if lastClear != nil {
			rec.LastClearAt = *lastClear
		}
		out = append(out, rec)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: iterate code attest push budgets: %w", err)
	}
	return out, nil
}

func (s *Store) UpsertCodeAttestPushBudget(ctx context.Context, rec contracts.CodeAttestPushBudget) error {
	if rec.SEPubKey == "" {
		return nil
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	_, err := s.pool.Exec(ctx,
		`INSERT INTO code_attest_push_budgets (
			se_pubkey, token_hash, next_push_at, updated_at
		 ) VALUES ($1, $2, $3, $4)
		 ON CONFLICT (se_pubkey, token_hash) DO UPDATE SET
			next_push_at = GREATEST(
				code_attest_push_budgets.next_push_at,
				EXCLUDED.next_push_at
			),
			updated_at = EXCLUDED.updated_at`,
		rec.SEPubKey, rec.TokenHash, rec.NextPushAt, rec.UpdatedAt,
	)
	if err != nil {
		return fmt.Errorf("store: upsert code attest push budget: %w", err)
	}
	return nil
}

func (s *Store) DeleteCodeAttestPushBudget(ctx context.Context, seKey string) error {
	if seKey == "" {
		return nil
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if _, err := s.pool.Exec(ctx,
		`DELETE FROM code_attest_push_budgets WHERE se_pubkey = $1`, seKey,
	); err != nil {
		return fmt.Errorf("store: delete code attest push budget: %w", err)
	}
	return nil
}

func (s *Store) ReserveCodeAttestPushBudget(
	ctx context.Context,
	seKey, tokenHash string,
	now, nextPushAt time.Time,
) (bool, error) {
	if seKey == "" || tokenHash == "" || !nextPushAt.After(now) {
		return false, errors.New("store: invalid code attest push reservation")
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	// Token row = per-token cooldown (A-B-A retention). Sentinel row
	// (token_hash = '') = per-SE-key admission floor: a NOVEL token (no row) is
	// only admitted once the floor has elapsed, so fabricated fresh tokens
	// cannot mint fresh budgets (Codex P1).
	//
	// Novel-token admission is serialized on the sentinel row itself: the floor
	// is created-or-advanced FIRST, and only the statement whose ON CONFLICT
	// guard passes against the row's latest committed version proceeds to
	// insert the token row. Two blue-green coordinators racing distinct novel
	// tokens for one SE key therefore cannot both admit — the loser re-checks
	// the winner's freshly raised floor and returns floor-blocked, even when
	// neither snapshot saw a sentinel (or a floor block) at statement start.
	var admitted bool
	err := s.pool.QueryRow(ctx,
		`WITH known AS (
			SELECT 1 FROM code_attest_push_budgets
			 WHERE se_pubkey = $1 AND token_hash = $2
		),
		floor_acquired AS (
			INSERT INTO code_attest_push_budgets (
				se_pubkey, token_hash, next_push_at, updated_at
			)
			SELECT $1, '', $4, $3
			 WHERE NOT EXISTS (SELECT 1 FROM known)
			ON CONFLICT (se_pubkey, token_hash) DO UPDATE SET
				next_push_at = EXCLUDED.next_push_at,
				updated_at = EXCLUDED.updated_at
			WHERE code_attest_push_budgets.next_push_at <= $3
			RETURNING 1
		),
		admitted AS (
			INSERT INTO code_attest_push_budgets (
				se_pubkey, token_hash, next_push_at, updated_at
			)
			SELECT $1, $2, $4, $3
			 WHERE EXISTS (SELECT 1 FROM known)
			    OR EXISTS (SELECT 1 FROM floor_acquired)
			ON CONFLICT (se_pubkey, token_hash) DO UPDATE SET
				next_push_at = EXCLUDED.next_push_at,
				updated_at = EXCLUDED.updated_at
			WHERE code_attest_push_budgets.next_push_at <= $3
			RETURNING 1
		),
		floor_raised AS (
			-- Known-token admissions raise the floor too; novel admissions
			-- already set it in floor_acquired. The two paths are mutually
			-- exclusive, so the sentinel row is written at most once here.
			INSERT INTO code_attest_push_budgets (
				se_pubkey, token_hash, next_push_at, updated_at
			)
			SELECT $1, '', $4, $3
			  FROM admitted
			 WHERE EXISTS (SELECT 1 FROM known)
			ON CONFLICT (se_pubkey, token_hash) DO UPDATE SET
				next_push_at = GREATEST(
					code_attest_push_budgets.next_push_at,
					EXCLUDED.next_push_at
				),
				updated_at = EXCLUDED.updated_at
		)
		SELECT EXISTS (SELECT 1 FROM admitted)`,
		seKey, tokenHash, now, nextPushAt,
	).Scan(&admitted)
	if err != nil {
		return false, fmt.Errorf("store: reserve code attest push budget: %w", err)
	}
	if admitted {
		// Bound rows per SE key: keep the newest token rows plus the floor
		// sentinel. Best-effort — a failure only delays GC to the next push.
		if _, err := s.pool.Exec(ctx,
			`DELETE FROM code_attest_push_budgets
			  WHERE se_pubkey = $1 AND token_hash <> ''
			    AND token_hash NOT IN (
				SELECT token_hash FROM code_attest_push_budgets
				 WHERE se_pubkey = $1 AND token_hash <> ''
				 ORDER BY updated_at DESC, token_hash DESC
				 LIMIT $2
			    )`,
			seKey, contracts.CodeAttestPushBudgetMaxTokenRows,
		); err != nil {
			return true, nil
		}
	}
	return admitted, nil
}

// ClearCodeAttestPushFloor drops the per-SE-key novel-token admission floor so
// a genuinely rotated token can be challenged promptly. Per-token cooldown rows
// are untouched (A-B-A retention). The clear is compare-and-set on the
// sentinel's durable last_clear_at: it is honored only when the previous
// durable clear is at least cooldown old (NULL = never cleared → honored), so
// the anti-abuse spacing between rotation clears holds across coordinator
// restarts and blue-green peers — not just within one process. The sentinel row
// is kept (next_push_at=now lifts the floor; last_clear_at=now starts the next
// cooldown). Returns the durable last-clear instant (now when honored, the
// pre-statement one when throttled) and whether the clear was honored.
func (s *Store) ClearCodeAttestPushFloor(
	ctx context.Context, seKey string, now time.Time, cooldown time.Duration,
) (time.Time, bool, error) {
	if seKey == "" {
		return time.Time{}, false, nil
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	var (
		cleared   bool
		lastClear time.Time
	)
	// The outer SELECT sees the pre-statement snapshot (data-modifying CTE
	// semantics); when the CAS wins the caller's last-clear is `now`, so the
	// snapshot value is only reported on the throttled path. COALESCE covers
	// the no-sentinel / never-cleared cases conservatively with `now`.
	err := s.pool.QueryRow(ctx,
		`WITH cleared AS (
			INSERT INTO code_attest_push_budgets (
				se_pubkey, token_hash, next_push_at, updated_at, last_clear_at
			) VALUES ($1, '', $2, $2, $2)
			ON CONFLICT (se_pubkey, token_hash) DO UPDATE SET
				next_push_at = EXCLUDED.next_push_at,
				updated_at = EXCLUDED.updated_at,
				last_clear_at = EXCLUDED.last_clear_at
			WHERE code_attest_push_budgets.last_clear_at IS NULL
			   OR code_attest_push_budgets.last_clear_at <= $3
			RETURNING 1
		)
		SELECT EXISTS (SELECT 1 FROM cleared),
		       COALESCE((
			SELECT last_clear_at FROM code_attest_push_budgets
			 WHERE se_pubkey = $1 AND token_hash = ''
		       ), $2)`,
		seKey, now, now.Add(-cooldown),
	).Scan(&cleared, &lastClear)
	if err != nil {
		return time.Time{}, false, fmt.Errorf("store: clear code attest push floor: %w", err)
	}
	if cleared {
		lastClear = now
	}
	return lastClear, cleared, nil
}
