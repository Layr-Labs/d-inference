package store

import (
	"context"
	"fmt"
	"time"
)

type cachedPrice struct {
	input, output int64
	at            time.Time
}

func (s *PostgresStore) SetModelPrice(accountID, model string, inputPrice, outputPrice int64) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`INSERT INTO model_prices (account_id, model, input_price, output_price, updated_at)
		 VALUES ($1, $2, $3, $4, NOW())
		 ON CONFLICT (account_id, model) DO UPDATE SET
		   input_price = $3, output_price = $4, updated_at = NOW()`,
		accountID, model, inputPrice, outputPrice,
	)
	if err != nil {
		return fmt.Errorf("store: set model price: %w", err)
	}

	s.invalidateModelPrice(accountID, model)

	return nil
}

func (s *PostgresStore) GetModelPrice(accountID, model string) (int64, int64, bool) {
	key := accountID + ":" + model

	// Check in-memory cache (30-second TTL).
	s.priceCacheMu.RLock()
	if cached, ok := s.priceCache[key]; ok && time.Since(cached.at) < 30*time.Second {
		s.priceCacheMu.RUnlock()
		return cached.input, cached.output, true
	}
	generation := s.priceCacheGeneration
	s.priceCacheMu.RUnlock()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var input, output int64
	err := s.pool.QueryRow(ctx,
		`SELECT input_price, output_price FROM model_prices WHERE account_id = $1 AND model = $2`,
		accountID, model,
	).Scan(&input, &output)
	if err != nil {
		return 0, 0, false
	}

	// An in-flight caller keeps its SQL result, but a completed local write
	// prevents that older result from becoming the next caller's cache hit.
	s.priceCacheMu.Lock()
	if generation == s.priceCacheGeneration {
		s.priceCache[key] = cachedPrice{input: input, output: output, at: time.Now()}
	}
	s.priceCacheMu.Unlock()

	return input, output, true
}

func (s *PostgresStore) ListModelPrices(accountID string) []ModelPrice {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT account_id, model, input_price, output_price FROM model_prices WHERE account_id = $1 ORDER BY model`,
		accountID,
	)
	if err != nil {
		return nil
	}
	defer rows.Close()

	var prices []ModelPrice
	for rows.Next() {
		var mp ModelPrice
		if err := rows.Scan(&mp.AccountID, &mp.Model, &mp.InputPrice, &mp.OutputPrice); err != nil {
			continue
		}
		prices = append(prices, mp)
	}
	return prices
}

func (s *PostgresStore) DeleteModelPrice(accountID, model string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tag, err := s.pool.Exec(ctx,
		`DELETE FROM model_prices WHERE account_id = $1 AND model = $2`,
		accountID, model,
	)
	if err != nil {
		return fmt.Errorf("store: delete model price: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return fmt.Errorf("no custom price for model %q", model)
	}
	s.invalidateModelPrice(accountID, model)
	return nil
}

// invalidateModelPrice fences delayed reads after either successful mutation.
// One generation covers the cache: writes are rare, and unrelated reads may
// safely skip a fill without retaining a generation entry for every price key.
func (s *PostgresStore) invalidateModelPrice(accountID, model string) {
	s.priceCacheMu.Lock()
	s.priceCacheGeneration++
	delete(s.priceCache, accountID+":"+model)
	s.priceCacheMu.Unlock()
}
