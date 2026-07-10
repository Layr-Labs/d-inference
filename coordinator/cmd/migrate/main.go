// Command migrate applies external SQL migrations (plan §20).
// Application startup must never run DDL — operators run this before boot.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/eigeninference/d-inference/coordinator/migrate"
	"github.com/jackc/pgx/v5/pgxpool"
)

func main() {
	dir := flag.String("dir", "coordinator-rs/migrations", "directory of ordered .sql files")
	dsn := flag.String("database-url", os.Getenv("EIGENINFERENCE_DATABASE_URL"), "Postgres URL")
	flag.Parse()
	if *dsn == "" {
		fmt.Fprintln(os.Stderr, "migrate: -database-url or EIGENINFERENCE_DATABASE_URL required")
		os.Exit(1)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	pool, err := pgxpool.New(ctx, *dsn)
	if err != nil {
		fmt.Fprintf(os.Stderr, "migrate: connect: %v\n", err)
		os.Exit(1)
	}
	defer pool.Close()

	_, _ = pool.Exec(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (
		id TEXT PRIMARY KEY,
		applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
	)`)

	r := &migrate.Runner{
		Exec: func(ctx context.Context, sql string) error {
			_, err := pool.Exec(ctx, sql)
			return err
		},
		Record: func(ctx context.Context, name string) error {
			_, err := pool.Exec(ctx,
				`INSERT INTO schema_migrations (id) VALUES ($1) ON CONFLICT DO NOTHING`, name)
			return err
		},
		Applied: func(ctx context.Context, name string) (bool, error) {
			var n int
			err := pool.QueryRow(ctx, `SELECT COUNT(*) FROM schema_migrations WHERE id = $1`, name).Scan(&n)
			return n > 0, err
		},
	}
	if err := r.ApplyDir(ctx, *dir); err != nil {
		fmt.Fprintf(os.Stderr, "migrate: %v\n", err)
		os.Exit(1)
	}
	fmt.Println("migrate: ok")
}
