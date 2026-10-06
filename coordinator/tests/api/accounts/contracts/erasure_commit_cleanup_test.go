package accounts_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/api/readcache"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/postgres"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/erasurefixture"
)

func TestErasureRuntimeCleanupAfterCommittedCancellation(t *testing.T) {
	for _, step := range []string{"confirm", "scrub"} {
		t.Run(step, func(t *testing.T) {
			databaseURL := os.Getenv("DATABASE_URL")
			if databaseURL == "" {
				t.Skip("DATABASE_URL not set — skipping PostgreSQL integration test")
			}
			ctx := context.Background()
			st, err := postgres.NewPostgres(ctx, store.Config{DatabaseURL: databaseURL})
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(st.Close)
			a := erasurefixture.SeedAccount(t, st)
			now := time.Now().UTC()
			plan, err := st.PlanAccountErasure(ctx, a.AccountID, nil)
			if err != nil {
				t.Fatal(err)
			}
			if _, err = st.SaveErasurePlan(ctx, a.AccountID, "admin_key", plan.ErasureCounts, nil, "token", now.Add(time.Hour)); err != nil {
				t.Fatal(err)
			}
			traced, interrupted := erasurefixture.CancelAfterCommit(t, databaseURL)
			cached := store.NewCached(traced, store.DefaultCacheConfig())
			logger := slog.New(slog.DiscardHandler)
			reg := registry.New(logger)
			ledger := payments.NewLedger(cached)
			srv := api.NewRuntime(api.RuntimeDependencies{Registry: reg, Store: cached, Ledger: ledger, ReadCache: readcache.New(), Logger: logger}, api.ServerConfig{}).Server
			t.Cleanup(srv.Close)
			srv.SetAdminKey("admin-key")
			provider := reg.Register(a.ProviderID, nil, &protocol.RegisterMessage{})
			provider.Mu().Lock()
			provider.AccountID = a.AccountID
			provider.Mu().Unlock()
			ledger.RecordUsage(a.AccountID, payments.UsageEntry{JobID: "cached-job", Model: "m"})
			// Prime both auth caches before erasure changes their backing rows.
			if _, err := cached.GetUserByAccountID(a.AccountID); err != nil {
				t.Fatal(err)
			}
			if status := erasureBalanceStatus(srv, a.RawKey); status != http.StatusOK {
				t.Fatalf("prime API key cache: status %d", status)
			}
			if step == "confirm" {
				body, err := json.Marshal(map[string]string{"account_id": a.AccountID, "confirm_token": "token", "email": a.Email})
				if err != nil {
					t.Fatal(err)
				}
				r := httptest.NewRequest(http.MethodPost, "/v1/admin/accounts/"+a.AccountID+"/erasure", bytes.NewReader(body)).WithContext(interrupted)
				r.Header.Set("Authorization", "Bearer admin-key")
				w := httptest.NewRecorder()
				srv.Handler().ServeHTTP(w, r)
				if w.Code != http.StatusOK {
					t.Fatalf("confirmation lost committed result: %d %s", w.Code, w.Body.String())
				}
			} else {
				// Confirm outside this runtime so the scrub must clear all primed caches.
				if _, err := st.RequestAccountErasure(ctx, store.ErasureConfirm{AccountID: a.AccountID, ConfirmToken: "token", Email: a.Email, Actor: "admin_key", Now: now}); err != nil {
					t.Fatal(err)
				}
				srv.StartAccountErasureLoop(interrupted)
				select {
				case <-interrupted.Done():
				case <-time.After(5 * time.Second):
					t.Fatal("scrub did not commit")
				}
				deadline := time.Now().Add(5 * time.Second)
				for reg.GetProvider(a.ProviderID) != nil || len(ledger.Usage(a.AccountID)) != 0 || erasureBalanceStatus(srv, a.RawKey) != http.StatusUnauthorized {
					if time.Now().After(deadline) {
						t.Fatal("committed scrub did not disconnect the provider and clear usage/auth caches")
					}
					time.Sleep(10 * time.Millisecond)
				}
			}
			if !errors.Is(interrupted.Err(), context.Canceled) {
				t.Fatal("tracer did not cancel after COMMIT")
			}
			if reg.GetProvider(a.ProviderID) != nil {
				t.Fatal("committed confirmation did not disconnect the provider")
			}
			if status := erasureBalanceStatus(srv, a.RawKey); status != http.StatusUnauthorized {
				t.Fatalf("cached API key still authorizes after erasure: %d", status)
			}
			if _, err := cached.GetUserByAccountID(a.AccountID); !errors.Is(err, store.ErrNotFound) {
				t.Fatalf("cached personal user survived erasure: %v", err)
			}
		})
	}
}

func erasureBalanceStatus(srv *api.Server, key string) int {
	r := httptest.NewRequest(http.MethodGet, "/v1/payments/balance", nil)
	r.Header.Set("Authorization", "Bearer "+key)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, r)
	return w.Code
}
