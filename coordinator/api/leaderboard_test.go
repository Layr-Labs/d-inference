package api

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/jackc/pgx/v5"
)

// Exercise the public route against a real throwaway database. Renaming the
// earnings table makes the actual query fail; restoring it permits recovery
// without swapping the server's store or mocking query results.
func TestLeaderboardStoreErrorIs503NotEmptyBoard(t *testing.T) {
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
	defer admin.Close(context.Background())
	name := fmt.Sprintf("leaderboard_api_%d", time.Now().UnixNano())
	quotedName := pgx.Identifier{name}.Sanitize()
	if _, err := admin.Exec(ctx, "CREATE DATABASE "+quotedName); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if _, err := admin.Exec(context.Background(), "DROP DATABASE "+quotedName+" WITH (FORCE)"); err != nil {
			t.Errorf("drop test database: %v", err)
		}
	}()
	dbURL, err := url.Parse(rawURL)
	if err != nil {
		t.Fatal(err)
	}
	dbURL.Path = "/" + name
	pg, err := store.NewPostgres(ctx, store.Config{DatabaseURL: dbURL.String()})
	if err != nil {
		t.Fatal(err)
	}
	defer pg.Close()
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
	defer control.Close(context.Background())
	srv := NewServer(registry.New(quietLogger()), pg, ServerConfig{}, quietLogger())
	defer srv.Close()
	httpServer := httptest.NewServer(srv.Handler())
	defer httpServer.Close()
	const key = "leaderboard:earnings:24h:50"
	get := func(wantStatus int) map[string]any {
		t.Helper()
		res, err := httpServer.Client().Get(httpServer.URL + "/v1/leaderboard?metric=earnings&window=24h")
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		var body map[string]any
		if err := json.NewDecoder(res.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		if res.StatusCode != wantStatus {
			t.Fatalf("status=%d want=%d body=%v", res.StatusCode, wantStatus, body)
		}
		return body
	}
	if _, err := control.Exec(ctx, "ALTER TABLE provider_earnings RENAME TO earnings_unavailable"); err != nil {
		t.Fatal(err)
	}
	body := get(http.StatusServiceUnavailable)
	errObj, _ := body["error"].(map[string]any)
	if errObj["code"] != "service_unavailable" {
		t.Fatalf("error envelope = %v", errObj)
	}
	if _, ok := srv.readCache.Get(key); ok {
		t.Fatal("failed leaderboard was cached")
	}
	if _, err := control.Exec(ctx, "ALTER TABLE earnings_unavailable RENAME TO provider_earnings"); err != nil {
		t.Fatal(err)
	}
	body = get(http.StatusOK)
	entries, _ := body["entries"].([]any)
	if len(entries) != 1 {
		t.Fatalf("entries=%v, want one recovered provider", entries)
	}
	if _, ok := srv.readCache.Get(key); !ok {
		t.Fatal("successful leaderboard was not cached")
	}
}

func TestLeaderboardEmptyWindowIs200(t *testing.T) {
	srv, _ := testServer(t)
	httpServer := httptest.NewServer(srv.Handler())
	defer httpServer.Close()
	res, err := httpServer.Client().Get(httpServer.URL + "/v1/leaderboard?window=7d")
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", res.StatusCode)
	}
	var body struct {
		Entries []any `json:"entries"`
	}
	if err := json.NewDecoder(res.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	if body.Entries == nil || len(body.Entries) != 0 {
		t.Fatalf("entries = %v, want empty array", body.Entries)
	}
	if _, ok := srv.readCache.Get("leaderboard:earnings:7d:50"); !ok {
		t.Fatal("successful empty leaderboard was not cached")
	}
}
