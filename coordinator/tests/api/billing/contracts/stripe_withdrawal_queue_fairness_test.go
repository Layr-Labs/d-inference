package billing_test

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/billing/payouts"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/internal/billing/payoutrecovery"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"github.com/eigeninference/d-inference/coordinator/store/postgres"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestStripeWithdrawalQueueUnavailableCohortDoesNotStarveFundableRow(t *testing.T) {
	for _, unavailable := range []string{"disabled", "account_lookup_error", "schedule_repair_error"} {
		t.Run(unavailable, func(t *testing.T) {
			var mu sync.Mutex
			transfers, scheduleRepairs := 0, 0
			remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				mu.Lock()
				defer mu.Unlock()
				switch {
				case strings.HasPrefix(r.URL.Path, "/v1/accounts/"):
					id := strings.TrimPrefix(r.URL.Path, "/v1/accounts/")
					if id == "acct_fundable" {
						_, _ = w.Write([]byte(healthyAccountJSON(id, "US", "full", false)))
						return
					}
					if r.Method == http.MethodPost {
						scheduleRepairs++
						w.WriteHeader(http.StatusServiceUnavailable)
						_, _ = w.Write([]byte(`{"error":{"message":"schedule repair unavailable"}}`))
						return
					}
					if unavailable == "account_lookup_error" {
						w.WriteHeader(http.StatusServiceUnavailable)
						_, _ = w.Write([]byte(`{"error":{"message":"account lookup unavailable"}}`))
						return
					}
					account := healthyAccountJSON(id, "US", "full", false)
					if unavailable == "disabled" {
						account = strings.Replace(account, `"payouts_enabled":true`, `"payouts_enabled":false`, 1)
					} else {
						account = strings.Replace(account, `"interval":"daily"`, `"interval":"manual"`, 1)
					}
					_, _ = w.Write([]byte(account))
				case r.URL.Path == "/v1/transfers":
					transfers++
					if err := r.ParseForm(); err != nil || r.Form.Get("destination") != "acct_fundable" {
						t.Errorf("dispatched unavailable destination: %v", r.Form)
					}
					_, _ = w.Write([]byte(`{"id":"tr_fundable","amount":500,"destination":"acct_fundable"}`))
				default:
					t.Errorf("unexpected Stripe request %s %s", r.Method, r.URL.Path)
					w.WriteHeader(http.StatusNotFound)
				}
			}))
			defer remote.Close()
			st := memory.NewMemory(store.Config{})
			service, logger := stripeQueueWorkerService(t, st, remote)
			stripeQueueWorkerAccount(t, st, "fairness", 1_010_000_000)
			base := time.Now().Add(-time.Hour)
			for i := range 201 {
				stripeQueueWorkerWithdrawal(t, st, fmt.Sprintf("unavailable-%03d", i), "fairness", "acct_unavailable", base.Add(time.Duration(i)*time.Second))
			}
			stripeQueueWorkerWithdrawal(t, st, "fundable", "fairness", "acct_fundable", base.Add(201*time.Second))
			worker := payouts.New(service, logger)
			worker.ProcessStripeWithdrawalQueue(context.Background())
			first, err := st.GetStripeWithdrawal("unavailable-000")
			if err != nil || !first.TransferLeaseUntil.After(time.Now()) || !first.UpdatedAt.After(base) {
				t.Fatalf("unavailable row was not deferred: %+v, %v", first, err)
			}
			worker.ProcessStripeWithdrawalQueue(context.Background())
			fundable, err := st.GetStripeWithdrawal("fundable")
			if err != nil || fundable.Status != "transferred" || fundable.TransferID != "tr_fundable" {
				t.Fatalf("older unavailable rows starved fundable withdrawal: %+v, %v", fundable, err)
			}
			for i := range 201 {
				wd, err := st.GetStripeWithdrawal(fmt.Sprintf("unavailable-%03d", i))
				if err != nil || wd.Status != "queued" || wd.Refunded || wd.TransferAttempt != 0 || wd.TransferDispatchAttempts != 0 || !wd.TransferStartedAt.IsZero() {
					t.Fatalf("account unavailability consumed a send or refunded earnings: %+v, %v", wd, err)
				}
			}
			if b, wb := st.GetBalanceWithWithdrawable("fairness"); b != 0 || wb != 0 {
				t.Fatalf("reserved earnings changed: balance=%d withdrawable=%d", b, wb)
			}
			mu.Lock()
			defer mu.Unlock()
			if transfers != 1 || (unavailable == "schedule_repair_error" && scheduleRepairs != 201) {
				t.Fatalf("unexpected dispatches or repairs: transfers=%d repairs=%d", transfers, scheduleRepairs)
			}
		})
	}
}

func TestStripeWithdrawalQueueRemovedAccountPreservesPriorUnconfirmedSend(t *testing.T) {
	var mu sync.Mutex
	var transferKeys []string
	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		if r.URL.Path == "/v1/transfers" {
			transferKeys = append(transferKeys, r.Header.Get("Idempotency-Key"))
		} else if !strings.HasPrefix(r.URL.Path, "/v1/accounts/") {
			t.Errorf("unexpected Stripe request %s", r.URL.Path)
		}
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"error":{"code":"resource_missing","message":"No such account"}}`))
	}))
	defer remote.Close()
	st := memory.NewMemory(store.Config{})
	service, logger := stripeQueueWorkerService(t, st, remote)
	stripeQueueWorkerAccount(t, st, "unconfirmed", 5_000_000)
	stripeQueueWorkerWithdrawal(t, st, "unconfirmed", "unconfirmed", "acct_gone", time.Now().Add(-time.Hour))
	claimed, err := st.ClaimStripeWithdrawal("unconfirmed", time.Now().Add(-6*time.Minute))
	if err != nil || claimed == nil {
		t.Fatalf("seed prior unconfirmed claim: %+v, %v", claimed, err)
	}
	payouts.New(service, logger).ProcessStripeWithdrawalQueue(context.Background())
	payoutrecovery.New(service, logger).RecoverStripeRefunds()
	wd, err := st.GetStripeWithdrawal("unconfirmed")
	if err != nil || wd.Status != "pending" || wd.Refunded || wd.TransferAttempt != 1 || wd.TransferDispatchAttempts != 2 || !wd.TransferStartedAt.Equal(claimed.TransferStartedAt) {
		t.Fatalf("account disappearance changed unconfirmed send safety: %+v, %v", wd, err)
	}
	if b, wb := st.GetBalanceWithWithdrawable("unconfirmed"); b != 0 || wb != 0 {
		t.Fatalf("unconfirmed send refunded earnings: balance=%d withdrawable=%d", b, wb)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(transferKeys) != 1 || transferKeys[0] != "wd-tr-unconfirmed-funding-1" {
		t.Fatalf("prior send was not retried with its original key: %v", transferKeys)
	}
}

func TestPostgresStripeWithdrawalQueueRemovedAccountRetriesDurableRejection(t *testing.T) {
	st, pool := stripeQueueWorkerPostgres(t)
	var mu sync.Mutex
	transfers := 0
	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		if r.URL.Path == "/v1/transfers" {
			transfers++
		}
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte(`{"error":{"code":"resource_missing","message":"No such account"}}`))
	}))
	defer remote.Close()
	service, logger := stripeQueueWorkerService(t, st, remote)
	stripeQueueWorkerAccount(t, st, "removed", 10_000_000)
	stripeQueueWorkerWithdrawal(t, st, "removed", "removed", "acct_gone", time.Now().Add(-time.Hour))
	// Sequences retain their increments when the trigger aborts the statement,
	// so both actual database writes fail once and succeed on the next attempt.
	_, err := pool.Exec(context.Background(), `
		CREATE SEQUENCE queue_rejection_write_attempts;
		CREATE SEQUENCE queue_refund_write_attempts;
		CREATE FUNCTION fail_first_queue_rejection_and_refund() RETURNS trigger LANGUAGE plpgsql AS $$
		BEGIN
			IF OLD.status IN ('queued', 'pending') AND NEW.status = 'failed' AND nextval('queue_rejection_write_attempts') = 1 THEN
				RAISE EXCEPTION 'injected queued rejection persistence failure';
			END IF;
			IF NOT OLD.refunded AND NEW.refunded AND nextval('queue_refund_write_attempts') = 1 THEN
				RAISE EXCEPTION 'injected refund persistence failure';
			END IF;
			RETURN NEW;
		END;
		$$;
		CREATE TRIGGER fail_queue_rejection_and_refund BEFORE UPDATE ON stripe_withdrawals
			FOR EACH ROW EXECUTE FUNCTION fail_first_queue_rejection_and_refund();`)
	if err != nil {
		t.Fatal(err)
	}
	worker := payouts.New(service, logger)
	worker.ProcessStripeWithdrawalQueue(context.Background())
	wd, err := st.GetStripeWithdrawal("removed")
	if err != nil || wd.Status != "queued" || wd.Refunded || wd.TransferAttempt != 0 || wd.TransferDispatchAttempts != 0 || !wd.TransferStartedAt.IsZero() || !wd.TransferLeaseUntil.After(time.Now()) || !wd.UpdatedAt.After(wd.CreatedAt) {
		t.Fatalf("failed rejection write consumed an unsent queue claim: %+v, %v", wd, err)
	}
	if _, err := pool.Exec(context.Background(), `UPDATE stripe_withdrawals SET transfer_lease_until=NOW()-INTERVAL '1 second' WHERE id='removed'`); err != nil {
		t.Fatal(err)
	}
	worker.ProcessStripeWithdrawalQueue(context.Background())
	wd, err = st.GetStripeWithdrawal("removed")
	if err != nil || wd.Status != "failed" || wd.Refunded || !strings.HasPrefix(wd.FailureReason, store.StripeConfirmedRejectionPrefix) || wd.TransferAttempt != 0 || wd.TransferDispatchAttempts != 0 || !wd.TransferStartedAt.IsZero() {
		t.Fatalf("confirmed rejection was not durable before refund recovery: %+v, %v", wd, err)
	}
	if b, wb := st.GetBalanceWithWithdrawable("removed"); b != 5_000_000 || wb != b {
		t.Fatalf("failed refund write was not atomic: balance=%d withdrawable=%d", b, wb)
	}
	recovery := payoutrecovery.New(service, logger)
	recovery.RecoverStripeRefunds()
	recovery.RecoverStripeRefunds()
	worker.ProcessStripeWithdrawalQueue(context.Background())
	wd, err = st.GetStripeWithdrawal("removed")
	if err != nil || wd.Status != "failed" || !wd.Refunded || wd.TransferAttempt != 0 || wd.TransferDispatchAttempts != 0 {
		t.Fatalf("removed account did not recover its refund: %+v, %v", wd, err)
	}
	if b, wb := st.GetBalanceWithWithdrawable("removed"); b != 10_000_000 || wb != b {
		t.Fatalf("removed-account refund was duplicated or lost: balance=%d withdrawable=%d", b, wb)
	}
	var refunds int
	if err := pool.QueryRow(context.Background(), `SELECT COUNT(*) FROM ledger_entries WHERE account_id='removed' AND entry_type='refund' AND reference='stripe_withdraw:removed'`).Scan(&refunds); err != nil || refunds != 1 {
		t.Fatalf("refund ledger count=%d: %v", refunds, err)
	}
	mu.Lock()
	defer mu.Unlock()
	if transfers != 0 {
		t.Fatalf("removed unsent destination received %d transfer requests", transfers)
	}
}

func stripeQueueWorkerService(t *testing.T, st store.Store, remote *httptest.Server) (*billing.Service, *slog.Logger) {
	t.Helper()
	t.Cleanup(setStripeAPIBase(remote.URL))
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	return billing.NewService(st, payments.NewLedger(st), logger, billing.Config{StripeSecretKey: "sk_test_fake", StripeConnectPlatformCountry: "US"}), logger
}

func stripeQueueWorkerAccount(t *testing.T, st store.Store, accountID string, earnings int64) {
	t.Helper()
	if err := st.CreateUser(&store.User{AccountID: accountID, PrivyUserID: "did:privy:" + accountID, Email: accountID + "@example.com"}); err != nil {
		t.Fatal(err)
	}
	if err := st.CreditWithdrawable(accountID, earnings, store.LedgerPayout, "earned"); err != nil {
		t.Fatal(err)
	}
}

func stripeQueueWorkerWithdrawal(t *testing.T, st store.Store, id, accountID, stripeAccountID string, createdAt time.Time) {
	t.Helper()
	wd := &store.StripeWithdrawal{ID: id, AccountID: accountID, StripeAccountID: stripeAccountID, AmountMicroUSD: 5_000_000, NetMicroUSD: 5_000_000, Method: "standard", Status: "queued", FailureReason: store.WithdrawalFundingReason, CreatedAt: createdAt, UpdatedAt: createdAt}
	if err := st.CreateStripeWithdrawalWithDebit(wd, store.LedgerStripePayout, "stripe_withdraw:"+id); err != nil {
		t.Fatal(err)
	}
}

func stripeQueueWorkerPostgres(t *testing.T) (*postgres.PostgresStore, *pgxpool.Pool) {
	t.Helper()
	source := os.Getenv("DATABASE_URL")
	if source == "" {
		t.Skip("DATABASE_URL not set — skipping PostgreSQL queue rejection recovery")
	}
	target, err := url.Parse(source)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	admin, err := pgx.Connect(ctx, source)
	if err != nil {
		t.Fatal(err)
	}
	name := "stripe_queue_test_" + strings.ReplaceAll(uuid.NewString(), "-", "_")
	quoted := pgx.Identifier{name}.Sanitize()
	if _, err := admin.Exec(ctx, "CREATE DATABASE "+quoted+" TEMPLATE template0"); err != nil {
		_ = admin.Close(context.Background())
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		if _, err := admin.Exec(ctx, "DROP DATABASE "+quoted+" WITH (FORCE)"); err != nil {
			t.Errorf("drop isolated stripe queue database: %v", err)
		}
		_ = admin.Close(ctx)
	})
	target.Path, target.RawPath = "/"+name, ""
	query := target.Query()
	query.Del("dbname")
	query.Del("database")
	target.RawQuery = query.Encode()
	st, err := postgres.NewPostgres(ctx, store.Config{DatabaseURL: target.String()})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(st.Close)
	pool, err := pgxpool.New(ctx, target.String())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	return st, pool
}
