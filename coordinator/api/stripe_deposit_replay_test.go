package api

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type depositCompletionFailureStore struct {
	store.Store
	failCompletion atomic.Bool
}

func (s *depositCompletionFailureStore) CompleteBillingSession(id string) error {
	if s.failCompletion.CompareAndSwap(true, false) {
		return errors.New("fixture: completion write failed")
	}
	return s.Store.CompleteBillingSession(id)
}

func TestStripeCheckoutWebhookCreditsEachSessionOnce(t *testing.T) {
	for _, tc := range []struct {
		name, sessionID                string
		persistSession, failCompletion bool
	}{
		{"completed_session_control", "session", true, false},
		{"no_session_metadata", "", false, false},
		{"missing_session_row", "session", false, false},
		{"completion_write_failed", "session", true, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			st := store.NewMemory(store.Config{})
			wrapped := &depositCompletionFailureStore{Store: st}
			wrapped.failCompletion.Store(tc.failCompletion)
			const accountID = "deposit-account"
			checkoutID := "cs_" + tc.name
			if tc.persistSession {
				if err := st.CreateBillingSession(&store.BillingSession{
					ID: tc.sessionID, AccountID: accountID, PaymentMethod: "stripe",
					AmountMicroUSD: 5_000_000, ExternalID: checkoutID, Status: "pending",
				}); err != nil {
					t.Fatal(err)
				}
			}
			logger := quietLogger()
			srv := NewServer(registry.New(logger), wrapped, ServerConfig{}, logger)
			t.Cleanup(srv.Close)
			const webhookSecret = "whsec_deposit_fixture"
			srv.SetBilling(billing.NewService(wrapped, payments.NewLedger(wrapped), logger, billing.Config{
				StripeSecretKey: "sk_test_fixture", StripeWebhookSecret: webhookSecret,
			}))
			ts := httptest.NewServer(srv.Handler())
			t.Cleanup(ts.Close)
			client := ts.Client()
			client.Timeout = 5 * time.Second
			payload, err := json.Marshal(map[string]any{
				"type": "checkout.session.completed",
				"data": map[string]any{"object": map[string]any{
					"id": checkoutID, "amount_total": 500, "currency": "usd", "payment_status": "paid",
					"metadata": map[string]string{"billing_session_id": tc.sessionID, "consumer_key": accountID},
				}},
			})
			if err != nil {
				t.Fatal(err)
			}
			for range 2 {
				req, err := http.NewRequest(http.MethodPost, ts.URL+"/v1/billing/stripe/webhook", bytes.NewReader(payload))
				if err != nil {
					t.Fatal(err)
				}
				req.Header = signedConnectRequest(t, payload, webhookSecret).Header
				resp, err := client.Do(req)
				if err != nil {
					t.Fatal(err)
				}
				body, err := io.ReadAll(resp.Body)
				resp.Body.Close()
				if err != nil {
					t.Fatal(err)
				}
				if resp.StatusCode != http.StatusOK {
					t.Fatalf("webhook status=%d body=%s", resp.StatusCode, body)
				}
			}
			if balance, withdrawable := st.GetBalanceWithWithdrawable(accountID); balance != 5_000_000 || withdrawable != 0 {
				t.Errorf("replayed deposit balances = (%d, %d), want (5000000, 0)", balance, withdrawable)
			}
			entries := st.LedgerHistory(accountID)
			if len(entries) != 1 || entries[0].Type != store.LedgerStripeDeposit || entries[0].Reference != "stripe:"+checkoutID {
				t.Errorf("replayed checkout must create one deposit ledger entry: %+v", entries)
			}
			if tc.persistSession {
				session, err := st.GetBillingSession(tc.sessionID)
				if err != nil || session.Status != "completed" {
					t.Errorf("session completion was not retained/retried: session=%+v error=%v", session, err)
				}
			}
		})
	}
}
