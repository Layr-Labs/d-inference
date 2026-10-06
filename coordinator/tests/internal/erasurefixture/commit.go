package erasurefixture

import (
	"context"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store/postgres"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// CancelAfterCommit opens a store on an already migrated test database. Its
// tracer cancels the returned context only after PostgreSQL confirms a successful
// COMMIT issued with it. Unrelated setup and background transactions cannot cancel it.
func CancelAfterCommit(t testing.TB, databaseURL string) (*postgres.PostgresStore, context.Context) {
	t.Helper()
	cfg, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	cfg.ConnConfig.Tracer = commitCancellationTracer{}
	pool, err := pgxpool.NewWithConfig(context.Background(), cfg)
	if err != nil {
		t.Fatal(err)
	}
	s := postgres.NewPostgresWithPool(pool)
	t.Cleanup(s.Close)
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	return s, context.WithValue(ctx, commitCancellationKey{}, cancel)
}

type commitCancellationKey struct{}
type commitCancellationTracer struct{}

func (t commitCancellationTracer) TraceQueryStart(ctx context.Context, _ *pgx.Conn, _ pgx.TraceQueryStartData) context.Context {
	return ctx
}

func (t commitCancellationTracer) TraceQueryEnd(ctx context.Context, _ *pgx.Conn, d pgx.TraceQueryEndData) {
	if cancel, ok := ctx.Value(commitCancellationKey{}).(context.CancelFunc); ok && d.Err == nil && d.CommandTag.String() == "COMMIT" {
		cancel()
	}
}
