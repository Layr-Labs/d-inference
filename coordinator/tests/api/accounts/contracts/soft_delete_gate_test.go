package accounts_test

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"github.com/eigeninference/d-inference/coordinator/store/postgres"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/erasurefixture"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
)

func softDeleteGateStore(t *testing.T, backend string) store.Store {
	t.Helper()
	if backend == "memory" {
		return memory.NewMemory(store.Config{})
	}
	// TestMain replaces this URL with a disposable database before any tests run.
	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		t.Skip("DATABASE_URL not set; skipping isolated PostgreSQL test")
	}
	st, err := postgres.NewPostgres(context.Background(), store.Config{DatabaseURL: databaseURL})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(st.Close)
	return st
}

func TestSoftDeleteMutationGateHTTP(t *testing.T) {
	for _, backend := range []string{"memory", "postgres"} {
		t.Run(backend, func(t *testing.T) {
			st := softDeleteGateStore(t, backend)
			for _, tc := range []struct {
				name string
				cfg  api.ServerConfig
			}{
				{"default", api.ServerConfig{}},
				{"false", api.ServerConfig{SoftDeleteMutationsEnabled: false}},
				{"true", api.ServerConfig{SoftDeleteMutationsEnabled: true}},
			} {
				t.Run(tc.name, func(t *testing.T) {
					logger := slog.New(slog.DiscardHandler)
					reg := registry.New(logger)
					srv := testkit.NewServer(t, reg, st, tc.cfg, logger)
					srv.SetAdminKey("admin-key")
					ts := httptest.NewServer(srv.Handler())
					t.Cleanup(ts.Close)
					sessions := testkit.NewSessions(t, srv, st)
					ctx := context.Background()

					t.Run("provider_removal", func(t *testing.T) {
						a := erasurefixture.SeedAccount(t, st)
						path := "/v1/me/providers/" + a.ProviderID
						ownerToken := sessions.Token(a.AccountID)
						before, err := st.GetProviderRecord(ctx, a.ProviderID)
						if err != nil {
							t.Fatal(err)
						}
						if code, body := erasureCall(t, ts, http.MethodDelete, path, "", nil); code != http.StatusUnauthorized {
							t.Fatalf("anonymous delete = %d %v", code, body)
						}
						if code, body := erasureCall(t, ts, http.MethodDelete, path, sessions.Token(erasurefixture.UniqueID("other")), nil); code != http.StatusForbidden {
							t.Fatalf("other owner's delete = %d %v", code, body)
						} else if strings.Contains(fmt.Sprint(body), before.SerialNumber) || strings.Contains(fmt.Sprint(body), a.AccountID) {
							t.Fatalf("other owner's delete exposed machine ownership: %v", body)
						}
						if code, body := erasureCall(t, ts, http.MethodDelete, "/v1/me/providers/"+erasurefixture.UniqueID("missing"), ownerToken, nil); code != http.StatusNotFound {
							t.Fatalf("missing provider delete = %d %v", code, body)
						}
						code, body := erasureCall(t, ts, http.MethodDelete, path, ownerToken, nil)
						after, err := st.GetProviderRecord(ctx, a.ProviderID)
						if tc.cfg.SoftDeleteMutationsEnabled {
							if code != http.StatusOK || body["deleted"] != true || body["rows_removed"] != float64(1) || err == nil || after != nil {
								t.Fatalf("enabled delete = %d %v; provider = %+v, %v", code, body, after, err)
							}
						} else {
							assertSoftDeleteDisabled(t, code, body)
							if err != nil || !reflect.DeepEqual(before, after) {
								t.Fatalf("blocked delete changed provider: before=%+v after=%+v err=%v", before, after, err)
							}
						}
					})

					for _, force := range []bool{false, true} {
						t.Run(fmt.Sprintf("erasure_force_%v", force), func(t *testing.T) {
							a := erasurefixture.SeedAccount(t, st)
							liveID := "live-" + a.ProviderID
							live := reg.Register(liveID, nil, &protocol.RegisterMessage{})
							live.Mu().Lock()
							live.AccountID = a.AccountID
							live.Mu().Unlock()
							path := "/v1/admin/accounts/" + a.AccountID + "/erasure"
							code, plan := erasureCall(t, ts, http.MethodPost, path+"/plan", "admin-key", nil)
							if code != http.StatusOK {
								t.Fatalf("plan = %d %v", code, plan)
							}
							before, _, err := st.GetAccountErasure(ctx, a.AccountID)
							if err != nil {
								t.Fatal(err)
							}
							beforeUser, err := st.GetUserByAccountID(a.AccountID)
							if err != nil {
								t.Fatal(err)
							}
							beforeProvider, err := st.GetProviderRecord(ctx, a.ProviderID)
							if err != nil {
								t.Fatal(err)
							}
							beforeToken, err := st.GetProviderToken(a.ProviderToken)
							if err != nil {
								t.Fatal(err)
							}
							beforeKeys, err := st.ListAPIKeys(a.AccountID)
							if err != nil {
								t.Fatal(err)
							}
							confirm := map[string]any{"account_id": a.AccountID, "confirm_token": plan["confirm_token"], "email": a.Email, "force": force}
							if code, body := erasureCall(t, ts, http.MethodPost, path, "", confirm); code != http.StatusUnauthorized && code != http.StatusForbidden {
								t.Fatalf("anonymous confirm = %d %v", code, body)
							}
							for _, target := range []string{path, "/v1/admin/accounts/" + erasurefixture.UniqueID("missing") + "/erasure"} {
								if code, body := erasureCall(t, ts, http.MethodPost, target, sessions.Token(erasurefixture.UniqueID("nonadmin")), confirm); code != http.StatusForbidden {
									t.Fatalf("non-admin confirm = %d %v", code, body)
								} else if strings.Contains(fmt.Sprint(body), a.AccountID) || strings.Contains(fmt.Sprint(body), a.Email) {
									t.Fatalf("non-admin confirm exposed account details: %v", body)
								}
							}
							code, body := erasureCall(t, ts, http.MethodPost, path, "admin-key", confirm)
							after, outbox, err := st.GetAccountErasure(ctx, a.AccountID)
							if err != nil {
								t.Fatal(err)
							}
							if tc.cfg.SoftDeleteMutationsEnabled {
								want := store.ErasurePending
								if force {
									want = store.ErasureErased
								}
								if code != http.StatusOK || after.State != want || reg.GetProvider(liveID) != nil {
									t.Fatalf("enabled confirm = %d %v; request=%+v", code, body, after)
								}
							} else {
								assertSoftDeleteDisabled(t, code, body)
								if !reflect.DeepEqual(before, after) || len(outbox) != 0 || reg.GetProvider(liveID) == nil {
									t.Fatalf("blocked confirm changed plan/outbox/connection: before=%+v after=%+v outbox=%+v", before, after, outbox)
								}
								user, err := st.GetUserByAccountID(a.AccountID)
								if err != nil || !reflect.DeepEqual(beforeUser, user) {
									t.Fatalf("blocked confirm changed user: %+v %v", user, err)
								}
								provider, err := st.GetProviderRecord(ctx, a.ProviderID)
								if err != nil || !reflect.DeepEqual(beforeProvider, provider) {
									t.Fatalf("blocked confirm changed provider: %+v %v", provider, err)
								}
								pt, err := st.GetProviderToken(a.ProviderToken)
								if err != nil || !reflect.DeepEqual(beforeToken, pt) {
									t.Fatalf("blocked confirm revoked provider token: %+v %v", pt, err)
								}
								keys, err := st.ListAPIKeys(a.AccountID)
								if err != nil || !reflect.DeepEqual(beforeKeys, keys) {
									t.Fatalf("blocked confirm changed API keys: %+v %v", keys, err)
								}
								if code, body := erasureCall(t, ts, http.MethodGet, "/v1/payments/balance", a.RawKey, nil); code != http.StatusOK {
									t.Fatalf("blocked confirm revoked API key = %d %v", code, body)
								}
							}
							if code, body := erasureCall(t, ts, http.MethodGet, path, "admin-key", nil); code != http.StatusOK {
								t.Fatalf("status = %d %v", code, body)
							}
						})
					}
				})
			}
		})
	}
}

func assertSoftDeleteDisabled(t *testing.T, code int, body map[string]any) {
	t.Helper()
	errBody, ok := body["error"].(map[string]any)
	if code != http.StatusServiceUnavailable || !ok || errBody["type"] != "soft_delete_mutations_disabled" {
		t.Fatalf("disabled mutation = %d %v", code, body)
	}
}

func TestSoftDeleteGateAllowsCancelOfPriorErasure(t *testing.T) {
	for _, backend := range []string{"memory", "postgres"} {
		t.Run(backend, func(t *testing.T) {
			st := softDeleteGateStore(t, backend)
			a := erasurefixture.SeedAccount(t, st)
			erasurefixture.PlanAndConfirm(t, st, a, time.Now(), time.Hour)
			logger := slog.New(slog.DiscardHandler)
			srv := testkit.NewServer(t, registry.New(logger), st, api.ServerConfig{}, logger)
			srv.SetAdminKey("admin-key")
			ts := httptest.NewServer(srv.Handler())
			t.Cleanup(ts.Close)
			path := "/v1/admin/accounts/" + a.AccountID + "/erasure"
			code, body := erasureCall(t, ts, http.MethodGet, path, "admin-key", nil)
			if code != http.StatusOK || body["request"].(map[string]any)["state"] != string(store.ErasurePending) {
				t.Fatalf("prior erasure status = %d %v", code, body)
			}
			code, body = erasureCall(t, ts, http.MethodPost, path+"/cancel", "admin-key", nil)
			if code != http.StatusOK || body["request"].(map[string]any)["state"] != string(store.ErasureCanceled) {
				t.Fatalf("prior erasure cancel = %d %v", code, body)
			}
			if _, err := st.GetUserByAccountID(a.AccountID); err != nil {
				t.Fatalf("canceled account was not restored: %v", err)
			}
			if _, err := st.GetProviderRecord(context.Background(), a.ProviderID); err != nil {
				t.Fatalf("canceled provider was not restored: %v", err)
			}
			if _, err := st.GetProviderToken(a.ProviderToken); err != nil {
				t.Fatalf("cancel did not restore the provider token: %v", err)
			}
			if _, err := st.AuthenticateKey(a.RawKey); err != nil {
				t.Fatalf("cancel did not restore the API key: %v", err)
			}
		})
	}
}
