package store

import (
	"context"
	"fmt"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// Compile-time check that PostgresStore implements Store.
var _ Store = (*PostgresStore)(nil)

// PostgresStore is a PostgreSQL-backed implementation of Store.
type PostgresStore struct {
	pool *pgxpool.Pool

	// In-memory cache for model prices. Keyed by "accountID:model".
	// Eliminates a DB round trip on every inference request for
	// platform pricing lookups (which change rarely).
	priceCacheMu sync.RWMutex
	priceCache   map[string]cachedPrice
}

type cachedPrice struct {
	input, output int64
	at            time.Time
}

// NewPostgres creates a new PostgresStore connected to the given database URL.
// It runs schema migrations on startup.
func NewPostgres(ctx context.Context, scfg Config) (*PostgresStore, error) {
	cfg, err := pgxpool.ParseConfig(scfg.DatabaseURL)
	if err != nil {
		return nil, fmt.Errorf("store: parse postgres config: %w", err)
	}

	// Pool was previously capped at 20, causing connection starvation under
	// load. The stats endpoint holds connections for up to 10s (full-table
	// scans on usage), billing settlement takes 5-7 sequential operations,
	// and heartbeat upserts fire every 30s per provider. 20 connections is
	// exhausted by 3-4 concurrent inference completions + a single stats
	// cache miss.
	if cfg.MaxConns < 80 {
		cfg.MaxConns = 80
	}
	cfg.MinConns = 10
	cfg.MaxConnLifetime = 30 * time.Minute
	cfg.MaxConnIdleTime = 5 * time.Minute
	cfg.HealthCheckPeriod = 30 * time.Second

	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("store: connect to postgres: %w", err)
	}

	// Verify connectivity.
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("store: ping postgres: %w", err)
	}

	s := &PostgresStore{
		pool:       pool,
		priceCache: make(map[string]cachedPrice),
	}
	if err := s.migrate(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("store: run migrations: %w", err)
	}

	return s, nil
}

// Close shuts down the connection pool.
func (s *PostgresStore) Close() {
	s.pool.Close()
}
