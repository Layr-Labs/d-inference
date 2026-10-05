package postgres

import (
	"context"
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *PostgresStore) SetModelPrice(price store.ModelPrice) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`INSERT INTO model_prices (account_id, model, input_price, output_price, cache_read_price, updated_at)
		 VALUES ($1, $2, $3, $4, $5, NOW())
		 ON CONFLICT (account_id, model) DO UPDATE SET
		   input_price = $3, output_price = $4, cache_read_price = $5, updated_at = NOW()`,
		price.AccountID, price.Model, price.InputPrice, price.OutputPrice, price.CacheReadPrice,
	)
	if err != nil {
		return fmt.Errorf("store: set model price: %w", err)
	}

	// Invalidate cache.
	key := price.AccountID + ":" + price.Model
	s.priceCacheMu.Lock()
	delete(s.priceCache, key)
	s.priceCacheMu.Unlock()

	return nil
}

func (s *PostgresStore) GetModelPrice(accountID, model string) (store.ModelPrice, bool) {
	key := accountID + ":" + model

	// Check in-memory cache (30-second TTL).
	s.priceCacheMu.RLock()
	if cached, ok := s.priceCache[key]; ok && time.Since(cached.at) < 30*time.Second {
		s.priceCacheMu.RUnlock()
		return cached.price.Clone(), true
	}
	s.priceCacheMu.RUnlock()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	mp := store.ModelPrice{AccountID: accountID, Model: model}
	err := s.pool.QueryRow(ctx,
		`SELECT input_price, output_price, cache_read_price FROM model_prices WHERE account_id = $1 AND model = $2`,
		accountID, model,
	).Scan(&mp.InputPrice, &mp.OutputPrice, &mp.CacheReadPrice)
	if err != nil {
		return store.ModelPrice{}, false
	}

	// Populate cache.
	s.priceCacheMu.Lock()
	s.priceCache[key] = cachedPrice{price: mp.Clone(), at: time.Now()}
	s.priceCacheMu.Unlock()

	return mp, true
}

func (s *PostgresStore) ListModelPrices(accountID string) []store.ModelPrice {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT account_id, model, input_price, output_price, cache_read_price FROM model_prices WHERE account_id = $1 ORDER BY model`,
		accountID,
	)
	if err != nil {
		return nil
	}
	defer rows.Close()

	var prices []store.ModelPrice
	for rows.Next() {
		var mp store.ModelPrice
		if err := rows.Scan(&mp.AccountID, &mp.Model, &mp.InputPrice, &mp.OutputPrice, &mp.CacheReadPrice); err != nil {
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
	return nil
}
