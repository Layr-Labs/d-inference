package store

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func TestPostgresSandboxStartupWithSingleConnectionPool(t *testing.T) {
	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		t.Skip("DATABASE_URL not set — use a disposable test database")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	backend, err := newPostgresWithPoolConfig(ctx, Config{DatabaseURL: databaseURL}, func(config *pgxpool.Config) {
		config.MaxConns = 1
		config.MinConns = 0
	})
	if err != nil {
		t.Fatalf("single-connection startup migration: %v", err)
	}
	defer backend.Close()
	if err := backend.executeSchemaMigrations(ctx, sandboxSchemaMigrations()); err != nil {
		t.Fatalf("single-connection sandbox migration replay: %v", err)
	}
}
