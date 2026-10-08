package billing_test

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api/billing/payouts"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestStripeInsufficientFundingQueuesAndWorkerTransfersOnce(t *testing.T) {
	for _, method := range []string{"standard", "instant"} {
		t.Run(method, func(t *testing.T) {
			var mu sync.Mutex
			funded := false
			var transferKeys []string
			payoutsCreated := 0
			remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				mu.Lock()
				defer mu.Unlock()
				switch {
				case strings.HasPrefix(r.URL.Path, "/v1/accounts/"):
					_, _ = w.Write([]byte(healthyAccountJSON("acct_queue", "US", "full", true)))
				case r.URL.Path == "/v1/transfers":
					transferKeys = append(transferKeys, r.Header.Get("Idempotency-Key"))
					if !funded {
						w.WriteHeader(400)
						_, _ = w.Write([]byte(`{"error":{"message":"Insufficient funds","code":"balance_insufficient"}}`))
						return
					}
					_, _ = w.Write([]byte(`{"id":"tr_queue","amount":450,"destination":"acct_queue"}`))
				case r.URL.Path == "/v1/payouts":
					payoutsCreated++
					_, _ = w.Write([]byte(`{"id":"po_queue","amount":450,"arrival_date":1700000000}`))
				default:
					t.Errorf("unexpected %s", r.URL.Path)
					w.WriteHeader(404)
				}
			}))
			defer remote.Close()
			srv, st := stripePayoutsTestServer(t, false, remote)
			u := readyUser(t, st, "queue-account", "queue@example.com", true)
			if err := st.CreditWithdrawable(u.AccountID, 10_000_000, store.LedgerPayout, "earned"); err != nil {
				t.Fatal(err)
			}
			w := globalAPIRequest(t, srv, u, "/v1/billing/withdraw/stripe", fmt.Sprintf(`{"amount_usd":"5.00","method":%q}`, method))
			var response struct {
				Status string `json:"status"`
				ID     string `json:"withdrawal_id"`
			}
			if err := json.Unmarshal(w.Body.Bytes(), &response); err != nil || w.Code != 202 || response.Status != "queued" {
				t.Fatalf("%d %s", w.Code, w.Body.String())
			}
			if b, wb := st.GetBalanceWithWithdrawable(u.AccountID); b != 5_000_000 || wb != b {
				t.Fatalf("reservation %d %d", b, wb)
			}
			mu.Lock()
			funded = true
			mu.Unlock()
			worker := payouts.New(srv.Billing(), srv.logger)
			var wg sync.WaitGroup
			for range 8 {
				wg.Add(1)
				go func() { defer wg.Done(); worker.ProcessStripeWithdrawalQueue(context.Background()) }()
			}
			wg.Wait()
			wd, _ := st.GetStripeWithdrawal(response.ID)
			if wd.Status != "transferred" || wd.TransferID != "tr_queue" || wd.Refunded {
				t.Fatalf("worker result %+v", wd)
			}
			if method == "instant" && wd.PayoutID != "po_queue" {
				t.Fatalf("lost instant payout %+v", wd)
			}
			mu.Lock()
			defer mu.Unlock()
			if len(transferKeys) != 2 || transferKeys[0] == transferKeys[1] || !strings.HasSuffix(transferKeys[1], "-funding-1") {
				t.Fatalf("keys %v", transferKeys)
			}
			if method == "instant" && payoutsCreated != 1 {
				t.Fatalf("instant payouts %d", payoutsCreated)
			}
			if b, wb := st.GetBalanceWithWithdrawable(u.AccountID); b != 5_000_000 || wb != b {
				t.Fatalf("worker debited twice %d %d", b, wb)
			}
		})
	}
}

func TestStripeFundingQueueRevalidatesItsSavedDestination(t *testing.T) {
	for _, destination := range []string{"removed", "manual", "disabled"} {
		t.Run(destination, func(t *testing.T) {
			var mu sync.Mutex
			queued, healed := false, false
			transfers := 0
			remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				mu.Lock()
				defer mu.Unlock()
				switch {
				case strings.HasPrefix(r.URL.Path, "/v1/accounts/"):
					if r.Method == http.MethodPost {
						if err := r.ParseForm(); err != nil || r.Form.Get("settings[payouts][schedule][interval]") != "daily" {
							t.Error("queue did not restore automatic delivery")
						}
						healed = true
					} else if queued && destination == "removed" {
						w.WriteHeader(http.StatusNotFound)
						_, _ = w.Write([]byte(`{"error":{"code":"resource_missing","message":"No such account"}}`))
						return
					}
					account := healthyAccountJSON("acct_queue", "US", "full", false)
					if queued && destination == "manual" && !healed {
						account = strings.Replace(account, `"interval":"daily"`, `"interval":"manual"`, 1)
					}
					if queued && destination == "disabled" {
						account = strings.Replace(account, `"payouts_enabled":true`, `"payouts_enabled":false`, 1)
					}
					_, _ = w.Write([]byte(account))
				case r.URL.Path == "/v1/transfers":
					transfers++
					if !queued {
						w.WriteHeader(http.StatusBadRequest)
						_, _ = w.Write([]byte(`{"error":{"message":"Insufficient funds","code":"balance_insufficient"}}`))
						return
					}
					if destination == "manual" && !healed {
						t.Error("transferred before restoring automatic delivery")
					}
					_, _ = w.Write([]byte(`{"id":"tr_queue","amount":500,"destination":"acct_queue"}`))
				default:
					t.Errorf("unexpected %s", r.URL.Path)
					w.WriteHeader(http.StatusNotFound)
				}
			}))
			defer remote.Close()
			srv, st := stripePayoutsTestServer(t, false, remote)
			u := readyUser(t, st, "queue-account", "queue@example.com", false)
			if err := st.CreditWithdrawable(u.AccountID, 10_000_000, store.LedgerPayout, "earned"); err != nil {
				t.Fatal(err)
			}
			w := globalAPIRequest(t, srv, u, "/v1/billing/withdraw/stripe", `{"amount_usd":"5.00"}`)
			var response struct {
				ID string `json:"withdrawal_id"`
			}
			if err := json.Unmarshal(w.Body.Bytes(), &response); err != nil || w.Code != http.StatusAccepted {
				t.Fatal(w.Body.String())
			}
			mu.Lock()
			queued = true
			mu.Unlock()
			worker := payouts.New(srv.Billing(), srv.logger)
			worker.ProcessStripeWithdrawalQueue(context.Background())
			worker.ProcessStripeWithdrawalQueue(context.Background())
			wd, _ := st.GetStripeWithdrawal(response.ID)
			mu.Lock()
			defer mu.Unlock()
			switch destination {
			case "removed":
				if !wd.Refunded || wd.Status != "failed" || transfers != 1 || st.GetWithdrawableBalance(u.AccountID) != 10_000_000 {
					t.Fatalf("removed destination stranded queue or refunded twice: %+v", wd)
				}
			case "manual":
				if !healed || wd.Status != "transferred" || transfers != 2 || st.GetWithdrawableBalance(u.AccountID) != 5_000_000 {
					t.Fatalf("manual schedule stranded transfer: %+v", wd)
				}
			case "disabled":
				if wd.Status != "queued" || wd.TransferDispatchAttempts != 0 || wd.TransferAttempt != 0 || transfers != 1 || st.GetWithdrawableBalance(u.AccountID) != 5_000_000 {
					t.Fatalf("disabled bank burned a transfer attempt: %+v", wd)
				}
			}
		})
	}
}
