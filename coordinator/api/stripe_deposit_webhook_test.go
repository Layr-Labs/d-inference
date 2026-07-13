package api

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const stripeDepositWebhookSecret = "whsec_contract_test"

func TestStripeCheckoutCreatesLocalOrderBeforeExternalSession(t *testing.T) {
	type stripeRequest struct {
		idempotencyKey string
		form           url.Values
	}
	requests := make(chan stripeRequest, 1)
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		form, _ := url.ParseQuery(string(body))
		requests <- stripeRequest{idempotencyKey: r.Header.Get("Idempotency-Key"), form: form}
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"id":"cs_created_local_first","url":"https://checkout.test/session"}`)
	}))
	defer fakeStripe.Close()
	previousStripeURL := billing.SetStripeAPIBaseForTest(fakeStripe.URL)
	t.Cleanup(func() { billing.SetStripeAPIBaseForTest(previousStripeURL) })

	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	memory := store.NewMemory(store.Config{AdminKey: "test-key"})
	srv := NewServer(registry.New(logger), memory, ServerConfig{AdminKey: "test-key"}, logger)
	srv.SetBilling(billing.NewService(memory, payments.NewLedger(memory), logger, billing.Config{
		StripeSecretKey:  "sk_test_contract",
		StripeSuccessURL: "https://console.test/success",
		StripeCancelURL:  "https://console.test/cancel",
	}))
	server := httptest.NewServer(srv.Handler())
	defer server.Close()
	defer srv.Close()

	request, err := http.NewRequest(
		http.MethodPost,
		server.URL+"/v1/billing/stripe/create-session",
		strings.NewReader(`{"amount_usd":"5.25"}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer test-key")
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(response.Body)
		t.Fatalf("status = %d: %s", response.StatusCode, body)
	}
	var payload struct {
		SessionID string `json:"session_id"`
	}
	if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
		t.Fatal(err)
	}
	session, err := memory.GetBillingSession(payload.SessionID)
	if err != nil {
		t.Fatal(err)
	}
	if session.Status != "pending" || session.ExternalID != "cs_created_local_first" ||
		session.AmountMicroUSD != 5_250_000 || session.Currency != "usd" {
		t.Fatalf("local order = %+v", session)
	}
	stripeCall := <-requests
	if stripeCall.idempotencyKey != "checkout:"+payload.SessionID {
		t.Fatalf("Idempotency-Key = %q", stripeCall.idempotencyKey)
	}
	if stripeCall.form.Get("metadata[billing_session_id]") != payload.SessionID {
		t.Fatalf("Stripe metadata missing local order: %v", stripeCall.form)
	}
}

func TestStripeDepositWebhookAppliesOnceThroughHTTP(t *testing.T) {
	_, memory, server := stripeDepositWebhookServer(t)
	session := &store.BillingSession{
		ID: "billing-http-1", AccountID: "account-http-1", PaymentMethod: "stripe",
		Currency: "usd", AmountMicroUSD: 500_000, ExternalID: "cs_http_1",
		Status: "pending",
	}
	if err := memory.CreateBillingSession(session); err != nil {
		t.Fatal(err)
	}
	payload := stripeCheckoutEvent("evt_http_1", "cs_http_1", session.ID, 50, "usd")

	for range 2 {
		response := postStripeWebhook(t, server.URL, payload)
		if response.StatusCode != http.StatusOK {
			body, _ := io.ReadAll(response.Body)
			response.Body.Close()
			t.Fatalf("status = %d, want 200: %s", response.StatusCode, body)
		}
		response.Body.Close()
	}
	if balance := memory.GetBalance(session.AccountID); balance != session.AmountMicroUSD {
		t.Fatalf("balance = %d, want %d", balance, session.AmountMicroUSD)
	}
	stored, err := memory.GetBillingSession(session.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stored.Status != "completed" || stored.ProcessedEventID != "evt_http_1" {
		t.Fatalf("stored session = %+v", stored)
	}
}

func TestStripeDepositWebhookDurablyRejectsMismatchWithoutCredit(t *testing.T) {
	_, memory, server := stripeDepositWebhookServer(t)
	session := &store.BillingSession{
		ID: "billing-http-2", AccountID: "account-http-2", PaymentMethod: "stripe",
		Currency: "usd", AmountMicroUSD: 500_000, ExternalID: "cs_http_2",
		Status: "pending",
	}
	if err := memory.CreateBillingSession(session); err != nil {
		t.Fatal(err)
	}
	payload := stripeCheckoutEvent("evt_http_2", "cs_http_2", session.ID, 75, "usd")
	response := postStripeWebhook(t, server.URL, payload)
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want durable rejection 200", response.StatusCode)
	}
	if balance := memory.GetBalance(session.AccountID); balance != 0 {
		t.Fatalf("mismatched event credited balance %d", balance)
	}
	stored, err := memory.GetBillingSession(session.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stored.Status != "pending" {
		t.Fatalf("mismatched order status = %q, want pending", stored.Status)
	}
}

func stripeDepositWebhookServer(t *testing.T) (*Server, *store.MemoryStore, *httptest.Server) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	memory := store.NewMemory(store.Config{})
	srv := NewServer(registry.New(logger), memory, ServerConfig{}, logger)
	srv.SetBilling(billing.NewService(memory, payments.NewLedger(memory), logger, billing.Config{
		StripeSecretKey:     "sk_test_contract",
		StripeWebhookSecret: stripeDepositWebhookSecret,
	}))
	server := httptest.NewServer(srv.Handler())
	t.Cleanup(server.Close)
	t.Cleanup(srv.Close)
	return srv, memory, server
}

func stripeCheckoutEvent(eventID, checkoutID, billingSessionID string, amountCents int64, currency string) []byte {
	return []byte(fmt.Sprintf(
		`{"id":%q,"type":"checkout.session.completed","data":{"object":{"id":%q,"amount_total":%d,"currency":%q,"payment_status":"paid","metadata":{"billing_session_id":%q}}}}`,
		eventID, checkoutID, amountCents, currency, billingSessionID,
	))
}

func postStripeWebhook(t *testing.T, baseURL string, payload []byte) *http.Response {
	t.Helper()
	timestamp := time.Now().Unix()
	signed := fmt.Sprintf("%d.%s", timestamp, payload)
	mac := hmac.New(sha256.New, []byte(stripeDepositWebhookSecret))
	_, _ = mac.Write([]byte(signed))
	signature := hex.EncodeToString(mac.Sum(nil))
	request, err := http.NewRequest(
		http.MethodPost,
		baseURL+"/v1/billing/stripe/webhook",
		bytes.NewReader(payload),
	)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Stripe-Signature", fmt.Sprintf("t=%d,v1=%s", timestamp, signature))
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	return response
}
