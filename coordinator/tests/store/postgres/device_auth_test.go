package postgres_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/jackc/pgx/v5/pgconn"
)

func TestProviderTokenDatabaseFailureIsNotInvalid(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	s, err := openPostgresFixture(ctx, store.Config{DatabaseURL: newThrowawayTestDatabase(t)})
	if err != nil {
		t.Fatalf("open token store: %v", err)
	}
	t.Cleanup(s.Close)
	if _, err := s.pool.Exec(ctx, "DROP TABLE provider_tokens"); err != nil {
		t.Fatalf("drop token table: %v", err)
	}

	got, err := s.GetProviderToken("unavailable-token")
	if got != nil || err == nil || errors.Is(err, store.ErrProviderTokenInvalid) {
		t.Fatalf("database failure: got=%v err=%v, want storage error, not invalid token", got, err)
	}
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) || pgErr.Code != "42P01" {
		t.Fatalf("database error not preserved: %v, want undefined_table", err)
	}
}
