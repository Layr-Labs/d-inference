package postgres

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// CreateReferrer registers an account as a referrer with the given code.
func (s *PostgresStore) CreateReferrer(accountID, code string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`INSERT INTO referrers (account_id, code) VALUES ($1, $2)`,
		accountID, code,
	)
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return fmt.Errorf("%w: referral code or account already registered", store.ErrReferralConflict)
		}
		return fmt.Errorf("store: create referrer: %w", err)
	}
	return nil
}

// GetReferrerByCode returns the referrer for a given referral code.
func (s *PostgresStore) GetReferrerByCode(code string) (*store.Referrer, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var ref store.Referrer
	err := s.pool.QueryRow(ctx,
		`SELECT account_id, code, created_at FROM referrers WHERE code = $1`, code,
	).Scan(&ref.AccountID, &ref.Code, &ref.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, store.ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("store: referrer lookup: %w", err)
	}
	return &ref, nil
}

// GetReferrerByAccount returns the referrer record for an account.
func (s *PostgresStore) GetReferrerByAccount(accountID string) (*store.Referrer, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var ref store.Referrer
	err := s.pool.QueryRow(ctx,
		`SELECT account_id, code, created_at FROM referrers WHERE account_id = $1`, accountID,
	).Scan(&ref.AccountID, &ref.Code, &ref.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, store.ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("store: referrer lookup: %w", err)
	}
	return &ref, nil
}

// RecordReferral records that referredAccountID was referred by referrerCode.
func (s *PostgresStore) RecordReferral(referrerCode, referredAccountID string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	ref, err := s.GetReferrerByCode(referrerCode)
	if err != nil {
		return err
	}
	if ref.AccountID == referredAccountID {
		return fmt.Errorf("%w: cannot refer yourself", store.ErrReferralConflict)
	}
	var code string
	err = s.pool.QueryRow(ctx, `INSERT INTO referrals (referred_account,referrer_code) VALUES ($1,$2)
		ON CONFLICT (referred_account) DO UPDATE SET referrer_code=referrals.referrer_code
		WHERE referrals.referrer_code=EXCLUDED.referrer_code RETURNING referrer_code`, referredAccountID, referrerCode).Scan(&code)
	if errors.Is(err, pgx.ErrNoRows) {
		return fmt.Errorf("%w: account already has a referrer", store.ErrReferralConflict)
	}
	if err != nil {
		return fmt.Errorf("store: record referral: %w", err)
	}
	return nil
}

// GetReferrerForAccount returns the referrer code that referred this account.
func (s *PostgresStore) GetReferrerForAccount(accountID string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var code string
	err := s.pool.QueryRow(ctx,
		`SELECT referrer_code FROM referrals WHERE referred_account = $1`, accountID,
	).Scan(&code)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("store: lookup referrer: %w", err)
	}
	return code, nil
}

// GetReferralStats returns referral statistics for a code.
func (s *PostgresStore) GetReferralStats(code string) (*store.ReferralStats, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	stats := &store.ReferralStats{Code: code}
	err := s.pool.QueryRow(ctx, `SELECT
		(SELECT COUNT(*) FROM referrals f WHERE f.referrer_code=r.code),
		(SELECT COALESCE(SUM(amount_micro_usd),0) FROM ledger_entries l WHERE l.account_id=r.account_id AND l.entry_type=$2),
		(SELECT COALESCE(SUM(collected_micro_usd),0) FROM consumer_charge_settlements c WHERE c.referrer_account=r.account_id AND c.referrer_account<>'')
		FROM referrers r WHERE r.code=$1`, code, string(store.LedgerReferralReward)).Scan(&stats.TotalReferred, &stats.TotalRewardsMicroUSD, &stats.TotalReferredSpendMicroUSD)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, fmt.Errorf("store: referral stats: %w", store.ErrNotFound)
	}
	if err != nil {
		return nil, fmt.Errorf("store: referral stats: %w", err)
	}
	return stats, nil
}
