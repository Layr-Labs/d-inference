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
func Main(m *testing.M) {
	source := os.Getenv("DATABASE_URL")
	if source == "" {
		os.Exit(m.Run())
	}
	target, err := url.Parse(source)
	if err != nil || target.Scheme == "" || target.Host == "" {
		fmt.Fprintln(os.Stderr, "store tests require a PostgreSQL DATABASE_URL")
		os.Exit(1)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	admin, err := pgx.Connect(ctx, source)
	if err != nil {
		cancel()
		fmt.Fprintln(os.Stderr, "connect isolated store test database:", err)
		os.Exit(1)
	}
	name := fmt.Sprintf("store_test_%d_%d", os.Getpid(), time.Now().UnixNano())
	quoted := pgx.Identifier{name}.Sanitize()
	_, err = admin.Exec(ctx, "CREATE DATABASE "+quoted+" TEMPLATE template0")
	cancel()
	if err != nil {
		_ = admin.Close(context.Background())
		fmt.Fprintln(os.Stderr, "create isolated store test database:", err)
		os.Exit(1)
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
	_ = admin.Close(ctx)
	cancel()
	os.Exit(code)
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
