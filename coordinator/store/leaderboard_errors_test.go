package store

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func TestLeaderboardClosedPoolReturnsError(t *testing.T) {
	pool, err := pgxpool.New(context.Background(), "postgresql://unused@127.0.0.1:1/unused?sslmode=disable")
	if err != nil {
		t.Fatal(err)
	}
	pool.Close()
	s := &PostgresStore{pool: pool}
	rows, err := s.Leaderboard(LeaderboardEarnings, time.Time{}, 50)
	if err == nil || rows != nil {
		t.Fatalf("query failure returned rows=%v err=%v", rows, err)
	}
}

func TestLeaderboardScanFailureDoesNotReturnPartialRanking(t *testing.T) {
	dsn := os.Getenv("TEST_ARCHIVE_DATABASE_URL")
	if dsn == "" {
		dsn = os.Getenv("DATABASE_URL")
	}
	if dsn == "" {
		t.Skip("local PostgreSQL test database is required")
	}
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		t.Fatal("invalid test database configuration")
	}
	if cfg.ConnConfig.Host != "127.0.0.1" && cfg.ConnConfig.Host != "localhost" && cfg.ConnConfig.Host != "::1" {
		t.Fatal("test requires a local PostgreSQL database")
	}
	cfg.MaxConns = 1
	cfg.MinConns = 0
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	// Session-local fixture tables shadow real names without modifying persistent tables.
	for _, sql := range []string{
		`CREATE TEMP TABLE provider_earnings(account_id text,model text,amount_micro_usd bigint,prompt_tokens int,completion_tokens int,created_at timestamptz DEFAULT now())`,
		`CREATE TEMP TABLE ledger_entries(account_id text,entry_type text,amount_micro_usd bigint,created_at timestamptz DEFAULT now())`,
		`INSERT INTO provider_earnings(account_id,model,amount_micro_usd,prompt_tokens,completion_tokens) VALUES ('good','work',1,1,1),('good','work',1,1,1),('good','work',1,1,1),('overflow','work',9223372036854775807,1,1),('overflow','work',9223372036854775807,1,1)`,
	} {
		if _, err := pool.Exec(ctx, sql); err != nil {
			t.Fatal(err)
		}
	}
	s := &PostgresStore{pool: pool}
	rows, err := s.Leaderboard(LeaderboardJobs, time.Time{}, 50)
	if err == nil || rows != nil {
		t.Fatalf("overflow after a valid first row returned partial ranking=%v error=%v", rows, err)
	}
}
