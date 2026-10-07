package accounts_test

import (
	"context"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/erasurefixture"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
)

func TestSoftDeleteGateContinuesAcceptedWorkers(t *testing.T) {
	t.Setenv("EIGENINFERENCE_ERASURE_GRACE", "0s")
	for _, backend := range []string{"memory", "postgres"} {
		t.Run(backend, func(t *testing.T) {
			st := softDeleteGateStore(t, backend)
			logger := slog.New(slog.DiscardHandler)
			account := erasurefixture.UniqueID("acct-worker")
			stripeID := erasurefixture.UniqueID("acct_stripe")
			if err := st.CreateUser(&store.User{AccountID: account, PrivyUserID: "did:privy:" + account}); err != nil {
				t.Fatal(err)
			}
			if err := st.SetUserStripeAccount(account, stripeID, "ready", "US", "bank", "4242", false); err != nil {
				t.Fatal(err)
			}
			rawKey, _, err := st.CreateAPIKey(account, store.APIKeyCreate{Name: "prior key"})
			if err != nil {
				t.Fatal(err)
			}

			// Accept through the enabled HTTP server, then run cleanup on a new
			// default-disabled server, as after an operator disables the flag.
			enabled := testkit.NewServer(t, registry.New(logger), st, api.ServerConfig{
				AdminKey: "admin-key", SoftDeleteMutationsEnabled: true,
			}, logger)
			accept := httptest.NewServer(enabled.Handler())
			t.Cleanup(accept.Close)
			path := "/v1/admin/accounts/" + account + "/erasure"
			code, plan := erasureCall(t, accept, http.MethodPost, path+"/plan", "admin-key", nil)
			if code != http.StatusOK {
				t.Fatalf("plan = %d %v", code, plan)
			}
			confirmation := map[string]any{"account_id": account, "confirm_token": plan["confirm_token"]}
			code, body := erasureCall(t, accept, http.MethodPost, path, "admin-key", confirmation)
			if code != http.StatusOK || body["request"].(map[string]any)["state"] != string(store.ErasurePending) {
				t.Fatalf("accepted erasure = %d %v", code, body)
			}
			accept.Close()

			disabled := testkit.NewServer(t, registry.New(logger), st, api.ServerConfig{AdminKey: "admin-key"}, logger)
			ts := httptest.NewServer(disabled.Handler())
			t.Cleanup(ts.Close)
			code, body = erasureCall(t, ts, http.MethodPost, path, "admin-key", map[string]any{"force": true})
			assertSoftDeleteDisabled(t, code, body)
			if code, body := erasureCall(t, ts, http.MethodGet, "/v1/payments/balance", rawKey, nil); code != http.StatusUnauthorized {
				t.Fatalf("disabled gate restored an erased account's credentials = %d %v", code, body)
			}

			stripe, fake := newFakeStripe(t)
			stripe.on(http.MethodDelete, "/v1/accounts/"+stripeID, http.StatusOK, `{"deleted":true}`)
			previous := billing.SetStripeAPIBaseForTest(fake.URL)
			defer billing.SetStripeAPIBaseForTest(previous)
			disabled.SetBilling(billing.NewService(st, payments.NewLedger(st), logger, billing.Config{StripeConnectSecretKey: "sk_test_connect"}))

			ctx, stop := context.WithCancel(context.Background())
			defer stop()
			disabled.StartAccountErasureLoop(ctx)
			deadline := time.Now().Add(5 * time.Second)
			for {
				code, body = erasureCall(t, ts, http.MethodGet, path, "admin-key", nil)
				if code != http.StatusOK {
					t.Fatalf("worker status = %d %v", code, body)
				}
				if body["request"].(map[string]any)["state"] == string(store.ErasureErased) {
					break
				}
				if time.Now().After(deadline) {
					t.Fatalf("disabled gate stalled accepted erasure: %v", body)
				}
				time.Sleep(10 * time.Millisecond)
			}

			disabled.StartErasureOutboxLoop(ctx)
			deadline = time.Now().Add(5 * time.Second)
			for {
				_, items, err := st.GetAccountErasure(ctx, account)
				if err != nil {
					t.Fatal(err)
				}
				done := 0
				for _, item := range items {
					if item.State == store.ErasureOutboxDone {
						wantDone(t, item)
						done++
					}
				}
				if len(items) == 2 && done == len(items) {
					break
				}
				if time.Now().After(deadline) {
					t.Fatalf("disabled gate stalled accepted outbox: %+v", items)
				}
				time.Sleep(10 * time.Millisecond)
			}
			if calls := stripe.count("DELETE /v1/accounts/" + stripeID); calls != 1 {
				t.Fatalf("Stripe account deletion calls = %d, want 1", calls)
			}
		})
	}
}
