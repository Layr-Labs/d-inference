package reporting

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"net/url"
	"os"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/readcache"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/postgres"
	"github.com/jackc/pgx/v5"
)

// This decorator observes calls but always executes the real store query.
type leaderboardQueryCounter struct {
	store.Store
	calls atomic.Int64
	limit atomic.Int64
}

func (s *leaderboardQueryCounter) Leaderboard(metric store.LeaderboardMetric, since time.Time, limit int) ([]store.LeaderboardRow, error) {
	s.calls.Add(1)
	s.limit.Store(int64(limit))
	return s.Store.Leaderboard(metric, since, limit)
}

func newLeaderboardPostgresFixture(t *testing.T) (*Owner, *leaderboardQueryCounter, *pgx.Conn) {
	t.Helper()
	rawURL := os.Getenv("DATABASE_URL")
	if rawURL == "" {
		t.Skip("DATABASE_URL not set — skipping PostgreSQL integration test")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	admin, err := pgx.Connect(ctx, rawURL)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = admin.Close(context.Background()) })
	name := fmt.Sprintf("leaderboard_api_%d", time.Now().UnixNano())
	quotedName := pgx.Identifier{name}.Sanitize()
	if _, err := admin.Exec(ctx, "CREATE DATABASE "+quotedName); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cleanupCancel()
		if _, err := admin.Exec(cleanupCtx, "DROP DATABASE "+quotedName+" WITH (FORCE)"); err != nil {
			t.Errorf("drop test database: %v", err)
		}
	})
	dbURL, err := url.Parse(rawURL)
	if err != nil {
		t.Fatal(err)
	}
	dbURL.Path = "/" + name
	pg, err := postgres.NewPostgres(ctx, store.Config{DatabaseURL: dbURL.String()})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pg.Close)
	if err := pg.RecordProviderEarning(&store.ProviderEarning{
		AccountID: "acct-a", Model: "m", JobID: "leaderboard-job", AmountMicroUSD: 100,
		PromptTokens: 10, CompletionTokens: 5, CreatedAt: time.Now(),
	}); err != nil {
		t.Fatal(err)
	}
	control, err := pgx.Connect(ctx, dbURL.String())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = control.Close(context.Background()) })
	counter := &leaderboardQueryCounter{Store: pg}
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	srv := New(Dependencies{Registry: registry.New(logger), Store: counter, Logger: logger, Cache: readcache.New()})
	return srv, counter, control
}
