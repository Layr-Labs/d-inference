package testdb

import (
	"context"
	"errors"
	"net/url"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

func TestServerBudgetSerializesIndependentConnections(t *testing.T) {
	source := os.Getenv("DATABASE_URL")
	if source == "" {
		t.Skip("DATABASE_URL not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	first, err := acquireServerBudget(ctx, source)
	if err != nil {
		t.Fatal(err)
	}
	defer first.Close(context.Background())
	probe, err := pgx.Connect(ctx, source)
	if err != nil {
		t.Fatal(err)
	}
	defer probe.Close(context.Background())
	var acquired bool
	if err := probe.QueryRow(ctx, "SELECT pg_try_advisory_lock(hashtextextended('darkbloom.store.testdb.connection_budget', 0))").Scan(&acquired); err != nil {
		t.Fatal(err)
	}
	if acquired {
		t.Fatal("independent connection acquired the occupied server budget")
	}

	// A second session must wait, not acquire a reentrant lock on the first.
	waitCtx, waitCancel := context.WithTimeout(ctx, 250*time.Millisecond)
	second, err := acquireServerBudget(waitCtx, source)
	waitCancel()
	if second != nil {
		_ = second.Close(context.Background())
		t.Fatal("second connection acquired the occupied server budget")
	}
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("waiting connection error = %v, want deadline exceeded", err)
	}
	if err := first.Close(ctx); err != nil {
		t.Fatal(err)
	}
	// Closing the owner releases the lock, including after a cancelled waiter.
	// Other test packages may acquire it first, so retain the suite wait budget.
	third, err := acquireServerBudget(ctx, source)
	if err != nil {
		t.Fatalf("budget was not released: %v", err)
	}
	defer third.Close(context.Background())
}

func TestIsolatedURLCannotSelectConfiguredDatabase(t *testing.T) {
	t.Setenv("PGDATABASE", "configured")
	for _, query := range []string{
		"sslmode=disable",
		"dbname=configured&sslmode=disable",
		"database=configured&sslmode=disable",
		"dbname=configured&dbname=another&database=other&sslmode=disable&application_name=store-tests",
	} {
		t.Run(query, func(t *testing.T) {
			source, err := url.Parse("postgres://test@localhost:5432/configured?" + query)
			if err != nil {
				t.Fatal(err)
			}
			original := source.String()
			target := isolatedURL(*source, "store_test_owned")
			parsed, err := pgx.ParseConfig(target)
			if err != nil {
				t.Fatal(err)
			}
			if parsed.Database != "store_test_owned" {
				t.Fatalf("resolved database = %q, want isolated database", parsed.Database)
			}
			if parsed.Host != "localhost" || parsed.Port != 5432 || parsed.User != "test" {
				t.Fatal("isolation changed connection identity")
			}
			if got := parsed.RuntimeParams["application_name"]; got != source.Query().Get("application_name") {
				t.Fatalf("application_name = %q, connection options must be preserved", got)
			}
			if source.String() != original {
				t.Fatal("isolation modified the administrative URL")
			}
		})
	}
}
