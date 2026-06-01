package store

import (
	"context"
	"errors"
	"fmt"
	"time"
)

// --- Provider Tokens ---

func (s *PostgresStore) CreateProviderToken(pt *ProviderToken) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`INSERT INTO provider_tokens (token_hash, account_id, label, active)
		 VALUES ($1, $2, $3, $4)`,
		pt.TokenHash, pt.AccountID, pt.Label, pt.Active,
	)
	if err != nil {
		return fmt.Errorf("store: create provider token: %w", err)
	}
	return nil
}

func (s *PostgresStore) GetProviderToken(token string) (*ProviderToken, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	h := HashKey(token)
	var pt ProviderToken
	err := s.pool.QueryRow(ctx,
		`SELECT token_hash, account_id, label, active, created_at
		 FROM provider_tokens WHERE token_hash = $1 AND active = TRUE`, h,
	).Scan(&pt.TokenHash, &pt.AccountID, &pt.Label, &pt.Active, &pt.CreatedAt)
	if err != nil {
		return nil, fmt.Errorf("store: provider token not found: %w", err)
	}
	return &pt, nil
}

func (s *PostgresStore) RevokeProviderToken(token string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	h := HashKey(token)
	tag, err := s.pool.Exec(ctx,
		`UPDATE provider_tokens SET active = FALSE WHERE token_hash = $1`, h,
	)
	if err != nil {
		return fmt.Errorf("store: revoke provider token: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return errors.New("provider token not found")
	}
	return nil
}
