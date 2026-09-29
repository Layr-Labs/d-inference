package store

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestModelRevisionPromotionMissingModel(t *testing.T) {
	for name, st := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			err := st.PromoteModelVersion(uniqueID("missing-model"), "v1")
			if err == nil || !strings.Contains(err.Error(), "not found") {
				t.Fatalf("missing model promotion must report not found, got %v", err)
			}
			if name == "postgres" && !errors.Is(err, ErrNotFound) {
				t.Fatalf("parent-row miss lost the store not-found identity: %v", err)
			}
		})
	}
}

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
	readOnly := &PostgresStore{pool: pool}
	err = readOnly.PromoteModelVersion(uniqueID("missing-model"), "v1")
	var dbErr *pgconn.PgError
	if !errors.As(err, &dbErr) || dbErr.Code != "25006" {
		t.Fatalf("expected original read-only SQLSTATE 25006, got %v", err)
	}
	if errors.Is(err, ErrNotFound) || strings.Contains(err.Error(), "not found") {
		t.Fatalf("database failure was misclassified as missing model: %v", err)
	}
}
