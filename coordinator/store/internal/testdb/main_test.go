package testdb

import (
	"net/url"
	"testing"

	"github.com/jackc/pgx/v5"
)

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
