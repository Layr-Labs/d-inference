package testdb

import (
	"context"
	"fmt"
	"net/url"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// Main gives a test process its own database, including tests that reconnect
// directly through DATABASE_URL. The configured database is never migrated or
// truncated; it is used only to create and drop the disposable database.
// Tests within a process remain sequential because their fixture truncates tables.
// Separate databases isolate rows, not the server's connection budget. Store test
// processes sharing the administrative database also share a session advisory lock
// so their production-sized pools cannot exhaust the default PostgreSQL server.
func Main(m *testing.M) {
	os.Exit(run(m))
}

func run(m *testing.M) int {
	source := os.Getenv("DATABASE_URL")
	if source == "" {
		return m.Run()
	}
	target, err := url.Parse(source)
	if err != nil || target.Scheme == "" || target.Host == "" {
		fmt.Fprintln(os.Stderr, "store tests require a PostgreSQL DATABASE_URL")
		return 1
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	admin, err := acquireServerBudget(ctx, source)
	cancel()
	if err != nil {
		fmt.Fprintln(os.Stderr, "acquire isolated store test database budget:", err)
		return 1
	}
	defer admin.Close(context.Background())
	ctx, cancel = context.WithTimeout(context.Background(), 30*time.Second)
	name := fmt.Sprintf("store_test_%d_%d", os.Getpid(), time.Now().UnixNano())
	quoted := pgx.Identifier{name}.Sanitize()
	_, err = admin.Exec(ctx, "CREATE DATABASE "+quoted+" TEMPLATE template0")
	cancel()
	if err != nil {
		fmt.Fprintln(os.Stderr, "create isolated store test database:", err)
		return 1
	}
	if err := os.Setenv("DATABASE_URL", isolatedURL(*target, name)); err != nil {
		panic(err)
	}
	code := m.Run()
	ctx, cancel = context.WithTimeout(context.Background(), 30*time.Second)
	if _, err := admin.Exec(ctx, "DROP DATABASE "+quoted+" WITH (FORCE)"); err != nil {
		fmt.Fprintln(os.Stderr, "drop isolated store test database:", err)
		code = 1
	}
	cancel()
	return code
}

// The lock belongs to the connection, so closing it releases the budget even
// when a test process exits without reaching database cleanup.
func acquireServerBudget(ctx context.Context, source string) (*pgx.Conn, error) {
	admin, err := pgx.Connect(ctx, source)
	if err != nil {
		return nil, err
	}
	if _, err := admin.Exec(ctx, "SELECT pg_advisory_lock(hashtextextended('darkbloom.store.testdb.connection_budget', 0))"); err != nil {
		_ = admin.Close(context.Background())
		return nil, err
	}
	return admin, nil
}

func isolatedURL(target url.URL, name string) string {
	target.Path = "/" + name
	target.RawPath = ""
	// pgx applies database query parameters after the URL path.
	query := target.Query()
	query.Del("dbname")
	query.Del("database")
	target.RawQuery = query.Encode()
	return target.String()
}
