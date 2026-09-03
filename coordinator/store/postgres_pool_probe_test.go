package store

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// newPostgresWithMaxConns creates a PostgresStore with a specific pool size.
func newPostgresWithMaxConns(t *testing.T, maxConns int32) *PostgresStore {
	t.Helper()
	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		t.Skip("DATABASE_URL not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	cfg, err := pgxpool.ParseConfig(dbURL)
	if err != nil {
		t.Fatalf("ParseConfig: %v", err)
	}
	cfg.MaxConns = maxConns
	cfg.MinConns = 0

	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatalf("NewWithConfig: %v", err)
	}
	s := &PostgresStore{pool: pool}
	if err := s.migrate(ctx); err != nil {
		pool.Close()
		t.Fatalf("migrate: %v", err)
	}
	for _, table := range []string{"providers"} {
		if _, err := s.pool.Exec(ctx, "TRUNCATE "+table+" CASCADE"); err != nil {
			t.Fatalf("truncate %s: %v", table, err)
		}
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func TestPoolExhaustion_SmallPool(t *testing.T) {
	s := newPostgresWithMaxConns(t, 2)

	const numProviders = 40
	errs := make(chan error, numProviders)

	for i := 0; i < numProviders; i++ {
		go func(id int) {
			p := ProviderRecord{
				ID:           fmt.Sprintf("provider-exhaust-%d", id),
				Hardware:     json.RawMessage(`{"chip":"Apple M3 Max"}`),
				Models:       json.RawMessage(`[]`),
				Backend:      "vllm_mlx",
				TrustLevel:   "self_signed",
				RegisteredAt: time.Now(),
				LastSeen:     time.Now(),
			}
			errs <- s.UpsertProvider(context.Background(), p)
		}(i)
	}

	var failures int
	for i := 0; i < numProviders; i++ {
		if err := <-errs; err != nil {
			failures++
		}
	}

	if failures == 0 {
		t.Log("no failures with pool_max_conns=2 — query was fast enough to avoid exhaustion on this machine")
	} else {
		t.Logf("pool_max_conns=2: %d/%d upserts failed (expected — pool exhaustion)", failures, numProviders)
	}
}

// TestPoolExhaustion_SimulatedLatency reproduces the prod failure:
// 2 pool connections + 40 goroutines each holding a connection for 500ms
// (simulating EigenCloud→RDS network latency). Most goroutines timeout
// waiting in the pool queue — exactly what happens in production.
func TestPoolExhaustion_SimulatedLatency(t *testing.T) {
	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		t.Skip("DATABASE_URL not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	cfg, err := pgxpool.ParseConfig(dbURL)
	if err != nil {
		t.Fatalf("ParseConfig: %v", err)
	}
	cfg.MaxConns = 2
	cfg.MinConns = 0

	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatalf("NewWithConfig: %v", err)
	}
	defer pool.Close()

	const numWorkers = 40
	errs := make(chan error, numWorkers)

	for i := 0; i < numWorkers; i++ {
		go func() {
			qctx, qcancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer qcancel()
			_, err := pool.Exec(qctx, "SELECT pg_sleep(0.5)")
			errs <- err
		}()
	}

	var failures int
	for i := 0; i < numWorkers; i++ {
		if err := <-errs; err != nil {
			failures++
		}
	}

	t.Logf("pool_max_conns=2 + 500ms latency: %d/%d queries failed", failures, numWorkers)
	if failures == 0 {
		t.Error("expected some failures with only 2 connections and 500ms queries")
	}
}

func TestPoolExhaustion_AdequatePool(t *testing.T) {
	s := newPostgresWithMaxConns(t, 20)

	const numProviders = 40
	errs := make(chan error, numProviders)

	for i := 0; i < numProviders; i++ {
		go func(id int) {
			p := ProviderRecord{
				ID:           fmt.Sprintf("provider-ok-%d", id),
				Hardware:     json.RawMessage(`{"chip":"Apple M3 Max"}`),
				Models:       json.RawMessage(`[]`),
				Backend:      "vllm_mlx",
				TrustLevel:   "self_signed",
				RegisteredAt: time.Now(),
				LastSeen:     time.Now(),
			}
			errs <- s.UpsertProvider(context.Background(), p)
		}(i)
	}

	var failures int
	for i := 0; i < numProviders; i++ {
		if err := <-errs; err != nil {
			failures++
			t.Errorf("upsert failed with adequate pool: %v", err)
		}
	}

	if failures > 0 {
		t.Fatalf("pool_max_conns=20: %d/%d upserts failed — should not happen", failures, numProviders)
	}
	t.Logf("pool_max_conns=20: all %d upserts succeeded", numProviders)
}
