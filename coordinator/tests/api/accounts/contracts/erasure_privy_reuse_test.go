package accounts_test

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	neturl "net/url"
	"os"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/api/readcache"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"github.com/eigeninference/d-inference/coordinator/store/postgres"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/erasurefixture"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// privyReuseFixture is a composed server with the real Privy auth component,
// connected to an in-process Privy API, and the real erasure outbox worker.
type privyReuseFixture struct {
	srv   *api.Server
	st    store.Store
	privy *testkit.PrivyUsers
	http  *httptest.Server
}

// privyReuseBackends returns the memory store and, with DATABASE_URL, the
// PostgreSQL store.
func privyReuseBackends(t *testing.T) map[string]func(*testing.T) store.Store {
	backends := map[string]func(*testing.T) store.Store{
		"memory": func(*testing.T) store.Store { return memory.NewMemory(store.Config{}) },
	}
	if os.Getenv("DATABASE_URL") != "" {
		backends["postgres"] = func(t *testing.T) store.Store {
			st, _ := isolatedPostgres(t)
			return st
		}
	}
	return backends
}

// isolatedPostgres returns a PostgreSQL store on a new database, and the
// database URL. The outbox worker leases every due row of its database, so
// rows of other tests must not be there.
func isolatedPostgres(t *testing.T) (*postgres.PostgresStore, string) {
	t.Helper()
	ctx := context.Background()
	source, err := neturl.Parse(os.Getenv("DATABASE_URL"))
	if err != nil {
		t.Fatal(err)
	}
	admin, err := pgxpool.New(ctx, source.String())
	if err != nil {
		t.Fatal(err)
	}
	name := strings.ReplaceAll(erasurefixture.UniqueID("privy_reuse"), "-", "_")
	if _, err := admin.Exec(ctx, "CREATE DATABASE "+pgx.Identifier{name}.Sanitize()+" TEMPLATE template0"); err != nil {
		admin.Close()
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = admin.Exec(context.Background(), "DROP DATABASE "+pgx.Identifier{name}.Sanitize()+" WITH (FORCE)")
		admin.Close()
	})
	source.Path = "/" + name
	st, err := postgres.NewPostgres(ctx, store.Config{DatabaseURL: source.String()})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(st.Close)
	return st, source.String()
}

func newPrivyReuseFixture(t *testing.T, st store.Store) *privyReuseFixture {
	t.Helper()
	logger := slog.New(slog.DiscardHandler)
	ledger := payments.NewLedger(st)
	srv := api.NewRuntime(api.RuntimeDependencies{Registry: registry.New(logger), Store: st, Ledger: ledger, ReadCache: readcache.New(), Logger: logger}, api.ServerConfig{}).Server
	t.Cleanup(srv.Close)
	srv.SetAdminKey("admin-key")
	srv.SetBilling(billing.NewService(st, ledger, logger, billing.Config{MockMode: true}))
	fx := &privyReuseFixture{srv: srv, st: st, privy: testkit.NewPrivyUsers(t, srv, st)}
	fx.http = httptest.NewServer(srv.Handler())
	t.Cleanup(fx.http.Close)
	return fx
}

// scrub creates an account with Privy user did, erases it and returns the
// account ID.
func (fx *privyReuseFixture) scrub(t *testing.T, did string) string {
	t.Helper()
	a := erasurefixture.Account{AccountID: erasurefixture.UniqueID("acct-privy-reuse"), PrivyID: did}
	a.Email = a.AccountID + "@example.com"
	if err := fx.st.CreateUser(&store.User{AccountID: a.AccountID, PrivyUserID: did, Email: a.Email}); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	req := erasurefixture.PlanAndConfirm(t, fx.st, a, now, 0)
	if _, err := fx.st.ScrubAccount(context.Background(), req.ID, now); err != nil {
		t.Fatal(err)
	}
	return a.AccountID
}

// login calls a Privy-only endpoint with a token of did and returns the
// status and the error type.
func (fx *privyReuseFixture) login(t *testing.T, did string) (int, string) {
	t.Helper()
	req, err := http.NewRequest(http.MethodGet, fx.http.URL+"/v1/keys", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+fx.privy.Token(did))
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var body struct {
		Error struct {
			Type string `json:"type"`
		} `json:"error"`
	}
	_ = json.NewDecoder(resp.Body).Decode(&body)
	return resp.StatusCode, body.Error.Type
}

// privyRow returns the account's privy_user outbox row.
func (fx *privyReuseFixture) privyRow(t *testing.T, account string) store.ErasureOutboxItem {
	t.Helper()
	_, items, err := fx.st.GetAccountErasure(context.Background(), account)
	if err != nil {
		t.Fatal(err)
	}
	for _, it := range items {
		if it.Target == store.ErasureTargetPrivyUser {
			return it
		}
	}
	t.Fatalf("no privy_user row: %+v", items)
	return store.ErasureOutboxItem{}
}

// deliver runs the outbox worker until the account's privy_user row has a
// stored result, then stops it.
func (fx *privyReuseFixture) deliver(t *testing.T, account string) store.ErasureOutboxItem {
	t.Helper()
	before := fx.privyRow(t, account)
	ctx, stop := context.WithCancel(context.Background())
	defer stop()
	fx.srv.StartErasureOutboxLoop(ctx)
	deadline := time.Now().Add(10 * time.Second)
	for {
		row := fx.privyRow(t, account)
		if row.State != store.ErasureOutboxPending || row.Attempts != before.Attempts {
			return row
		}
		if time.Now().After(deadline) {
			t.Fatalf("privy_user row was not delivered: %+v", row)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// After the scrub, the erased account's Privy user ID cannot make a new
// account: a login answers 403 account_pending_deletion while the privy_user
// row is not done, including while a failed delivery waits for its retry.
// After the worker deletes the Privy user, a token issued before the
// deletion gets 401, and no account holds the ID.
func TestErasurePrivyUserIDCannotMakeAnAccountDuringOrAfterDeletion(t *testing.T) {
	for backend, open := range privyReuseBackends(t) {
		t.Run(backend, func(t *testing.T) {
			fx := newPrivyReuseFixture(t, open(t))
			did := erasurefixture.UniqueID("did:privy:reuse")
			account := fx.scrub(t, did)

			if status, kind := fx.login(t, did); status != http.StatusForbidden || kind != "account_pending_deletion" {
				t.Fatalf("login after the scrub = %d %q; want 403 account_pending_deletion", status, kind)
			}
			fx.privy.SetStatus(http.StatusInternalServerError)
			if row := fx.deliver(t, account); row.State != store.ErasureOutboxPending || row.Attempts != 1 {
				t.Fatalf("failed delivery = %+v; want a pending retry", row)
			}
			if status, kind := fx.login(t, did); status != http.StatusForbidden || kind != "account_pending_deletion" {
				t.Fatalf("login while the delivery retries = %d %q; want 403 account_pending_deletion", status, kind)
			}
			if _, err := fx.st.GetUserByPrivyID(did); err == nil {
				t.Fatal("a login during the deletion made an account")
			}

			// Run the retry now instead of after its backoff.
			fx.privy.SetStatus(http.StatusNoContent)
			row := fx.privyRow(t, account)
			rows, err := fx.st.LeaseDueErasureOutbox(context.Background(), row.NextAt, time.Now().UTC(), time.Minute, 1000)
			if err != nil {
				t.Fatal(err)
			}
			for _, r := range rows {
				if err := fx.st.SaveErasureOutboxResult(context.Background(), r.ID, store.ErasureOutboxResult{
					LeaseGeneration: r.LeaseGeneration, State: r.State, Attempts: r.Attempts, NextAt: time.Now().UTC(), LastError: r.LastError, ExternalID: r.ExternalID,
				}); err != nil {
					t.Fatal(err)
				}
			}
			if row := fx.deliver(t, account); row.State != store.ErasureOutboxDone {
				t.Fatalf("delivery = %+v; want done", row)
			}
			if !slices.Contains(fx.privy.Deleted(), did) {
				t.Fatalf("Privy delete requests = %v; want %s", fx.privy.Deleted(), did)
			}

			lookups := fx.privy.Lookups()
			if status, kind := fx.login(t, did); status != http.StatusUnauthorized || kind != "authentication_error" {
				t.Fatalf("login with a token issued before the deletion = %d %q; want 401 authentication_error", status, kind)
			}
			if fx.privy.Lookups() != lookups+1 {
				t.Fatal("the login did not ask Privy for the user")
			}
			if u, err := fx.st.GetUserByPrivyID(did); err == nil {
				t.Fatalf("a token of the deleted Privy user made an account: %+v", u)
			}
		})
	}
}

// A live account can hold the Privy user ID of an erased account only if a
// build without the CreateUser fence made it after the scrub. The worker then
// does not delete the Privy user, which is that account's login, and moves
// the row to manual_action. The live account can still log in.
func TestErasurePrivyDeliveryKeepsTheIdentityOfALiveAccount(t *testing.T) {
	if os.Getenv("DATABASE_URL") == "" {
		t.Skip("DATABASE_URL not set — skipping PostgreSQL integration test")
	}
	ctx := context.Background()
	st, url := isolatedPostgres(t)
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	fx := newPrivyReuseFixture(t, st)
	did := erasurefixture.UniqueID("did:privy:reuse")
	account := fx.scrub(t, did)
	// The insert of the build before the fence (users.go at 586f7e12).
	live := erasurefixture.UniqueID("acct-privy-live")
	if _, err := pool.Exec(ctx, `INSERT INTO users (account_id, privy_user_id, email, role, platform_fee_percent) VALUES ($1, $2, '', '', NULL)`, live, did); err != nil {
		t.Fatal(err)
	}

	row := fx.deliver(t, account)
	if row.State != store.ErasureOutboxManualAction || row.LastError != "a live account holds this Privy user; the worker did not delete it" || !row.HasExternalID {
		t.Fatalf("delivery = %+v; want manual_action that keeps the ID", row)
	}
	if slices.Contains(fx.privy.Deleted(), did) {
		t.Fatalf("the worker deleted the Privy user of a live account: %v", fx.privy.Deleted())
	}
	if status, kind := fx.login(t, did); status != http.StatusOK {
		t.Fatalf("login of the live account = %d %q; want 200", status, kind)
	}
}
