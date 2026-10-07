package postgres_test

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestPostgresModelRevisionPromotionPreservesParentLockError(t *testing.T) {
	st := testPostgresStore(t)
	// The row-lock query must distinguish a missing row from an actual database
	// failure. PostgreSQL rejects SELECT FOR UPDATE in a read-only transaction.
	cfg := st.pool.Config()
	cfg.AfterConnect = func(ctx context.Context, conn *pgx.Conn) error {
		_, err := conn.Exec(ctx, "SET default_transaction_read_only = on")
		return err
	}
	pool, err := pgxpool.NewWithConfig(context.Background(), cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	readOnly := bindPostgresFixture(pool)
	err = readOnly.PromoteModelVersion(uniqueID("missing-model"), "v1")
	var dbErr *pgconn.PgError
	if !errors.As(err, &dbErr) || dbErr.Code != "25006" {
		t.Fatalf("expected original read-only SQLSTATE 25006, got %v", err)
	}
	if errors.Is(err, store.ErrNotFound) || strings.Contains(err.Error(), "not found") {
		t.Fatalf("database failure was misclassified as missing model: %v", err)
	}
}
