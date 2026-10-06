package postgres_test

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	routesql "github.com/eigeninference/d-inference/coordinator/internal/store/routesql"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestPostgresInferenceRouteErrorReasonUpsertQualifiesTargetColumn(t *testing.T) {
	if !strings.Contains(routesql.ErrorReasonUpsertAssignment, "inference_routes.error_reason") {
		t.Fatalf("error_reason upsert fallback must qualify target table: %s", routesql.ErrorReasonUpsertAssignment)
	}
	if strings.Contains(routesql.ErrorReasonUpsertAssignment, "), error_reason)") {
		t.Fatalf("error_reason upsert fallback is ambiguous in ON CONFLICT: %s", routesql.ErrorReasonUpsertAssignment)
	}
}

// newPostgresWithMaxConns creates a postgresFixture with a specific pool size.
func newPostgresWithMaxConns(t *testing.T, maxConns int32) *postgresFixture {
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
	s := bindPostgresFixture(pool)
	if err := s.reopen(ctx); err != nil {
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
			p := store.ProviderRecord{
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

func TestPoolExhaustion_AdequatePool(t *testing.T) {
	s := newPostgresWithMaxConns(t, 20)

	const numProviders = 40
	errs := make(chan error, numProviders)

	for i := 0; i < numProviders; i++ {
		go func(id int) {
			p := store.ProviderRecord{
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

// TestPostgresMigrateNeverDeletesModelPrices pins the removal of the one-time
// Solana-era wallet-price cleanup. That DELETE ran before the users table
// existed on a fresh database, failed silently, left no marker and then ran on
// the next boot. A restart must now leave every model_prices row alone:
// platform defaults, user-backed prices, and rows whose account is not a user.
func TestPostgresMigrateNeverDeletesModelPrices(t *testing.T) {
	s := testPostgresStore(t)
	ctx := context.Background()

	// model_prices and schema_migrations are not in the harness truncate list;
	// reset them so the old cleanup's marker cannot mask a DELETE.
	if _, err := s.pool.Exec(ctx, "DELETE FROM model_prices"); err != nil {
		t.Fatalf("clean model_prices: %v", err)
	}
	if _, err := s.pool.Exec(ctx, "DELETE FROM schema_migrations WHERE id = 'cleanup_wallet_model_prices_v1'"); err != nil {
		t.Fatalf("clear old migration marker: %v", err)
	}
	if err := s.CreateUser(&store.User{AccountID: "acct-real", PrivyUserID: "did:privy:real"}); err != nil {
		t.Fatalf("create user: %v", err)
	}
	prices := []struct {
		account string
		model   string
	}{
		{"acct-real", "gemma-4-26b"},
		{"platform", "gpt-oss-20b"},
		{"acct-not-a-user", "gemma-4-26b"},
	}
	for _, p := range prices {
		if err := s.SetModelPrice(store.ModelPrice{AccountID: p.account, Model: p.model, InputPrice: 50_000, OutputPrice: 200_000}); err != nil {
			t.Fatalf("set %s price: %v", p.account, err)
		}
	}

	// Simulated first goose boot, which replays the baseline.
	replayMigrations(t, s)

	for _, p := range prices {
		if mp, ok := s.GetModelPrice(p.account, p.model); !ok || mp.InputPrice != 50_000 || mp.OutputPrice != 200_000 {
			t.Errorf("%s price = (%+v, %v) after restart, want (50000, 200000, true)", p.account, mp, ok)
		}
	}
}
