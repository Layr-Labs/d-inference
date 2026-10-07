package postgres_test

import (
	"context"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/store"
	production "github.com/eigeninference/d-inference/coordinator/store/postgres"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// postgresFixture owns the SQL connection used for fixture setup and inspection.
// It never retrieves the private pool from the production store.
type postgresFixture struct {
	*production.PostgresStore
	pool         *pgxpool.Pool
	separatePool bool
}

func openPostgresFixture(ctx context.Context, cfg store.Config) (*postgresFixture, error) {
	s, err := production.NewPostgres(ctx, cfg)
	if err != nil {
		return nil, err
	}
	pool, err := pgxpool.New(ctx, cfg.DatabaseURL)
	if err != nil {
		s.Close()
		return nil, err
	}
	return &postgresFixture{PostgresStore: s, pool: pool, separatePool: true}, nil
}

func bindPostgresFixture(pool *pgxpool.Pool) *postgresFixture {
	return &postgresFixture{PostgresStore: production.NewPostgresWithPool(pool), pool: pool}
}

func (s *postgresFixture) Close() {
	s.PostgresStore.Close()
	if s.separatePool {
		s.pool.Close()
	}
}

// Reopening exercises the same migration entry point as a process restart.
func (s *postgresFixture) reopen(ctx context.Context) error {
	restarted, err := production.NewPostgres(ctx, store.Config{DatabaseURL: s.pool.Config().ConnString()})
	if err != nil {
		return err
	}
	restarted.Close()
	return nil
}

func newPostgresWithPoolConfig(ctx context.Context, scfg store.Config, tune func(*pgxpool.Config)) (*postgresFixture, error) {
	bootstrap, err := production.NewPostgres(ctx, scfg)
	if err != nil {
		return nil, err
	}
	bootstrap.Close()
	cfg, err := pgxpool.ParseConfig(scfg.DatabaseURL)
	if err != nil {
		return nil, err
	}
	tune(cfg)
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, err
	}
	return bindPostgresFixture(pool), nil
}

type resetMarkerTraceKey struct{}
type resetMarkerTracer struct{ cancel context.CancelFunc }

func (t resetMarkerTracer) TraceQueryStart(ctx context.Context, _ *pgx.Conn, d pgx.TraceQueryStartData) context.Context {
	return context.WithValue(ctx, resetMarkerTraceKey{}, strings.Contains(d.SQL, "INSERT INTO cache_routing_meta"))
}
func (t resetMarkerTracer) TraceQueryEnd(ctx context.Context, _ *pgx.Conn, d pgx.TraceQueryEndData) {
	if marked, _ := ctx.Value(resetMarkerTraceKey{}).(bool); marked && d.Err == nil {
		t.cancel()
	}
}
