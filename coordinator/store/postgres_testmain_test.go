package store

import (
	"context"
	"fmt"
	"net/url"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

// TestMain isolates the entire PostgreSQL store suite from the database named
// by DATABASE_URL. Individual tests may freely exercise migrations, ownership
// activation, truncation, and failure recovery without altering shared state.
func TestMain(m *testing.M) {
	baseURL := os.Getenv("DATABASE_URL")
	if baseURL == "" {
		os.Exit(m.Run())
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	name := "darkbloom_go_store_test_" + uuid.NewString()
	testURL, err := postgresDatabaseURL(baseURL, name)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	connection, err := pgx.Connect(ctx, baseURL)
	if err != nil {
		fmt.Fprintf(os.Stderr, "connect PostgreSQL test server: %v\n", err)
		os.Exit(1)
	}
	if _, err := connection.Exec(ctx,
		"CREATE DATABASE "+pgx.Identifier{name}.Sanitize(),
	); err != nil {
		_ = connection.Close(ctx)
		fmt.Fprintf(os.Stderr, "create isolated PostgreSQL test database: %v\n", err)
		os.Exit(1)
	}
	_ = connection.Close(ctx)
	cancel()
	if err := os.Setenv("DATABASE_URL", testURL); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	code := m.Run()
	cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 15*time.Second)
	connection, err = pgx.Connect(cleanupCtx, baseURL)
	if err == nil {
		_, err = connection.Exec(cleanupCtx,
			"DROP DATABASE IF EXISTS "+pgx.Identifier{name}.Sanitize()+" WITH (FORCE)",
		)
		_ = connection.Close(cleanupCtx)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "drop isolated PostgreSQL test database: %v\n", err)
		code = 1
	}
	cleanupCancel()
	os.Exit(code)
}

func postgresDatabaseURL(baseURL, database string) (string, error) {
	parsed, err := url.Parse(baseURL)
	if err != nil {
		return "", fmt.Errorf("parse DATABASE_URL: %w", err)
	}
	if parsed.Scheme != "postgres" && parsed.Scheme != "postgresql" {
		return "", fmt.Errorf("DATABASE_URL scheme %q is not PostgreSQL", parsed.Scheme)
	}
	parsed.Path = "/" + database
	return parsed.String(), nil
}
