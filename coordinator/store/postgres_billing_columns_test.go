package store

import (
	"context"
	"net/url"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// The billing columns are read and written on every settlement: GetModelPrice
// selects model_prices.cache_read_price and RecordUsage inserts
// usage.cached_tokens. If adding either column fails at boot, startup must
// fail. Swallowing the error would boot a coordinator whose price lookups all
// miss (billing at the default rates) and whose usage inserts all fail.
func TestPostgresBillingColumnMigrationFailureAbortsStartup(t *testing.T) {
	for _, tc := range []struct{ table, column string }{
		{"usage", "cached_tokens"},
		{"model_prices", "cache_read_price"},
	} {
		t.Run(tc.table+"."+tc.column, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
			defer cancel()
			databaseURL := newThrowawayTestDatabase(t)
			s, err := NewPostgres(ctx, Config{DatabaseURL: databaseURL})
			if err != nil {
				t.Fatalf("NewPostgres on an empty database: %v", err)
			}
			// A database migrated by an older coordinator: the column is missing.
			if _, err := s.pool.Exec(ctx, "ALTER TABLE "+tc.table+" DROP COLUMN "+tc.column); err != nil {
				t.Fatalf("drop %s.%s: %v", tc.table, tc.column, err)
			}
			forgetMigrationVersions(t, s)
			s.Close()

			// A long reader holds the table, so the ADD COLUMN cannot take its
			// lock before the short lock_timeout below expires.
			holder, err := pgx.Connect(ctx, databaseURL)
			if err != nil {
				t.Fatalf("connect lock holder: %v", err)
			}
			defer holder.Close(context.Background())
			tx, err := holder.Begin(ctx)
			if err != nil {
				t.Fatalf("begin: %v", err)
			}
			defer func() { _ = tx.Rollback(context.Background()) }()
			if _, err := tx.Exec(ctx, "LOCK TABLE "+tc.table+" IN ACCESS SHARE MODE"); err != nil {
				t.Fatalf("lock %s: %v", tc.table, err)
			}

			timed, err := url.Parse(databaseURL)
			if err != nil {
				t.Fatal(err)
			}
			q := timed.Query()
			q.Set("lock_timeout", "300ms")
			timed.RawQuery = q.Encode()
			again, err := NewPostgres(ctx, Config{DatabaseURL: timed.String()})
			if err == nil {
				again.Close()
				t.Fatalf("NewPostgres succeeded although %s.%s could not be added; startup must fail", tc.table, tc.column)
			}
		})
	}
}
