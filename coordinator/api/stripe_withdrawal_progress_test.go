package api

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// A webhook can settle or refund the transfer while the HTTP withdrawal
// handler is still awaiting payouts.create. Its later progress write must not
// overwrite that newer terminal state with the handler's old transferred row.
func TestStripeWithdrawalProgressPreservesConcurrentTerminal(t *testing.T) {
	for _, terminal := range []string{"paid", "refunded"} {
		t.Run(terminal, func(t *testing.T) {
			var srv *Server
			var st *store.MemoryStore
			snapshots := make(chan store.StripeWithdrawal, 1)
			callbackErrors := make(chan error, 1)
			fake := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch {
				case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/v1/accounts/"):
					_, _ = w.Write([]byte(healthyAccountJSON(strings.TrimPrefix(r.URL.Path, "/v1/accounts/"), "US", "full", true)))
				case r.Method == http.MethodPost && r.URL.Path == "/v1/transfers":
					_, _ = w.Write([]byte(`{"id":"tr_progress","amount":450,"currency":"usd"}`))
				case r.Method == http.MethodPost && r.URL.Path == "/v1/payouts":
					row, err := st.GetStripeWithdrawalByTransferID("tr_progress")
					if err == nil {
						if terminal == "paid" {
							var applied bool
							applied, err = st.MarkStripeWithdrawalPaid(row.ID, "", "po_sweep")
							if err == nil && !applied {
								err = fmt.Errorf("paid transition not applied")
							}
						} else {
							result := deliverConnectWebhook(t, srv, transferReversedPayload("tr_progress"))
							if result.Code != http.StatusOK {
								err = fmt.Errorf("reversal status%d: %s", result.Code, result.Body.String())
							}
						}
					}
					if err == nil {
						row, err = st.GetStripeWithdrawal(row.ID)
					}
					if err != nil {
						callbackErrors <- err
						http.Error(w, "fixture failed", 500)
						return
					}
					snapshots <- *row
					_, _ = w.Write([]byte(`{"id":"po_progress","amount":450,"status":"pending","method":"instant"}`))
				default:
					http.Error(w, "unexpected path "+r.URL.Path, 500)
				}
			}))
			defer fake.Close()
			srv, st = stripePayoutsTestServer(t, false, fake)
			defer srv.Close()
			user := readyUser(t, st, "progress-user", "progress@example.com", true)
			if err := st.CreditWithdrawable(user.AccountID, 10_000_000, store.LedgerPayout, "progress-funding"); err != nil {
				t.Fatal(err)
			}
			req := withPrivyUser(httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(`{"amount_usd":"5.00","method":"instant"}`)), user)
			w := httptest.NewRecorder()
			srv.handleStripeWithdraw(w, req)
			select {
			case err := <-callbackErrors:
				t.Fatal(err)
			default:
			}
			var want store.StripeWithdrawal
			select {
			case want = <-snapshots:
			default:
				t.Fatalf("payout callback did not run: status%d %s", w.Code, w.Body.String())
			}
			got, err := st.GetStripeWithdrawal(want.ID)
			if err != nil {
				t.Fatal(err)
			}
			if w.Code != http.StatusConflict || !strings.Contains(w.Body.String(), "withdrawal_state_changed") {
				t.Fatalf("concurrent update response=%d %s", w.Code, w.Body.String())
			}
			if !reflect.DeepEqual(*got, want) {
				t.Fatalf("late progress replaced terminal row: got%+v want%+v", *got, want)
			}
		})
	}
}
