package billing

import (
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
	"os"
	"strings"
	"testing"
	"time"
)

// silentLogger keeps test output clean; switch to TextHandler if you're
// debugging a failing case.
func silentLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
}

// signWebhook produces a Stripe-Signature header for the given payload using
// the processor's webhook secret. Mirrors Stripe's reference implementation:
// "t=<unix>,v1=<HMAC-SHA256(t + . + payload)>".
func signWebhook(t *testing.T, p *StripeProcessor, payload []byte) string {
	t.Helper()
	ts := fmt.Sprintf("%d", time.Now().Unix())
	mac := hmac.New(sha256.New, []byte(p.webhookSecret))
	mac.Write([]byte(ts + "." + string(payload)))
	sig := hex.EncodeToString(mac.Sum(nil))
	return "t=" + ts + ",v1=" + sig
}

func TestFeeForInstantPayoutMicroUSD(t *testing.T) {
	cases := []struct {
		name      string
		grossUSD  int64 // micro-USD
		wantMicro int64
	}{
		// Below the floor — fee snaps to $0.50.
		{"one_dollar", 1_000_000, 500_000},
		{"five_dollar", 5_000_000, 500_000},
		{"thirty_dollar", 30_000_000, 500_000},
		// 1.5% kicks in above the $0.50 / 1.5% = ~$33.33 threshold.
		{"fifty_dollar", 50_000_000, 750_000},       // 1.5% of $50 = $0.75
		{"one_hundred", 100_000_000, 1_500_000},     // $1.50
		{"one_thousand", 1_000_000_000, 15_000_000}, // $15
		// Edge cases.
		{"zero", 0, 0},
		{"negative", -100, 0},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := FeeForInstantPayoutMicroUSD(tc.grossUSD)
			if got != tc.wantMicro {
				t.Errorf("FeeForInstantPayoutMicroUSD(%d) = %d, want %d", tc.grossUSD, got, tc.wantMicro)
			}
		})
	}
}

func TestFeeForMethodMicroUSD(t *testing.T) {
	if got := FeeForMethodMicroUSD("standard", 50_000_000); got != 0 {
		t.Errorf("standard fee should be 0, got %d", got)
	}
	if got := FeeForMethodMicroUSD("instant", 50_000_000); got != 750_000 {
		t.Errorf("instant fee on $50 should be $0.75, got %d", got)
	}
	if got := FeeForMethodMicroUSD("unknown", 50_000_000); got != 0 {
		t.Errorf("unknown method should default to 0 fee, got %d", got)
	}
}

// withTestStripe spins up an httptest server, points stripeAPIBase at it for
// the duration of the test, and returns the server + a client targeting it.
func withTestStripe(t *testing.T, handler http.HandlerFunc) (*httptest.Server, *StripeConnect) {
	t.Helper()
	srv := httptest.NewServer(handler)
	t.Cleanup(srv.Close)
	prev := stripeAPIBase
	stripeAPIBase = srv.URL
	t.Cleanup(func() { stripeAPIBase = prev })
	return srv, NewStripeConnect("sk_test_fake", "whsec_fake", "US", false, silentLogger())
}

func TestCreateExpressAccountSuccess(t *testing.T) {
	var captured *http.Request
	var capturedBody url.Values
	_, client := withTestStripe(t, func(w http.ResponseWriter, r *http.Request) {
		captured = r
		body, _ := io.ReadAll(r.Body)
		capturedBody, _ = url.ParseQuery(string(body))
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{
			"id": "acct_test_123",
			"email": "alice@example.com",
			"charges_enabled": false,
			"payouts_enabled": false,
			"details_submitted": false
		}`))
	})

	acct, err := client.CreateExpressAccount(CreateExpressAccountParams{
		Email: "alice@example.com",
	})
	if err != nil {
		t.Fatalf("create account: %v", err)
	}
	if acct.ID != "acct_test_123" {
		t.Errorf("got ID %q, want acct_test_123", acct.ID)
	}
	if captured.URL.Path != "/v1/accounts" {
		t.Errorf("path = %q, want /v1/accounts", captured.URL.Path)
	}
	if got := capturedBody.Get("type"); got != "express" {
		t.Errorf("type=%q, want express", got)
	}
	if got := capturedBody.Get("email"); got != "alice@example.com" {
		t.Errorf("email=%q, want alice@example.com", got)
	}
	if got := capturedBody.Get("country"); got != "US" {
		t.Errorf("country=%q, want US", got)
	}
	if auth := captured.Header.Get("Authorization"); auth != "Bearer sk_test_fake" {
		t.Errorf("Authorization header = %q", auth)
	}
}

func TestCreateExpressAccountStripeError(t *testing.T) {
	_, client := withTestStripe(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"error":{"message":"country is invalid","type":"invalid_request_error"}}`))
	})
	_, err := client.CreateExpressAccount(CreateExpressAccountParams{Email: "a@b.com"})
	if err == nil {
		t.Fatal("expected error")
	}
	if !strings.Contains(err.Error(), "country is invalid") {
		t.Errorf("error should surface Stripe's message; got %v", err)
	}
}

func TestCreateAccountLinkSuccess(t *testing.T) {
	var capturedBody url.Values
	_, client := withTestStripe(t, func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		capturedBody, _ = url.ParseQuery(string(body))
		_, _ = w.Write([]byte(`{"url":"https://connect.stripe.com/setup/abc123"}`))
	})
	link, err := client.CreateAccountLink("acct_test_123", "https://app/return", "https://app/refresh")
	if err != nil {
		t.Fatalf("create link: %v", err)
	}
	if link != "https://connect.stripe.com/setup/abc123" {
		t.Errorf("got link %q", link)
	}
	if capturedBody.Get("account") != "acct_test_123" {
		t.Errorf("account=%q", capturedBody.Get("account"))
	}
	if capturedBody.Get("type") != "account_onboarding" {
		t.Errorf("type=%q", capturedBody.Get("type"))
	}
	if capturedBody.Get("return_url") != "https://app/return" {
		t.Errorf("return_url=%q", capturedBody.Get("return_url"))
	}
}

func TestCreateAccountLinkRequiresAccount(t *testing.T) {
	_, client := withTestStripe(t, func(w http.ResponseWriter, r *http.Request) { t.Error("should not call Stripe") })
	_, err := client.CreateAccountLink("", "https://app/return", "https://app/refresh")
	if err == nil {
		t.Fatal("expected error for missing account")
	}
}

func TestGetAccountParsesDestinationAndInstantEligibility(t *testing.T) {
	_, client := withTestStripe(t, func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{
			"id": "acct_x",
			"charges_enabled": true,
			"payouts_enabled": true,
			"details_submitted": true,
			"requirements": {"currently_due": [], "disabled_reason": ""},
			"external_accounts": {"data": [
				{"object":"card","last4":"4242","brand":"visa","funding":"debit","default_for_currency":true}
			]}
		}`))
	})
	acct, err := client.GetAccount("acct_x")
	if err != nil {
		t.Fatalf("get account: %v", err)
	}
	if !acct.PayoutsEnabled {
		t.Error("payouts_enabled should be true")
	}
	if acct.DestinationType != "card" {
		t.Errorf("destination_type=%q, want card", acct.DestinationType)
	}
	if acct.DestinationLast4 != "4242" {
		t.Errorf("last4=%q", acct.DestinationLast4)
	}
	if !acct.InstantEligible {
		t.Error("debit card should be instant-eligible")
	}
}

func TestGetAccountCreditCardNotInstantEligible(t *testing.T) {
	_, client := withTestStripe(t, func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{
			"id": "acct_x",
			"payouts_enabled": true,
			"external_accounts": {"data": [
				{"object":"card","last4":"4242","brand":"visa","funding":"credit","default_for_currency":true}
			]}
		}`))
	})
	acct, _ := client.GetAccount("acct_x")
	if acct.InstantEligible {
		t.Error("credit card destinations should NOT be instant-eligible")
	}
}

func TestGetAccountBankDestination(t *testing.T) {
	_, client := withTestStripe(t, func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{
			"id": "acct_x",
			"payouts_enabled": true,
			"external_accounts": {"data": [
				{"object":"bank_account","last4":"6789","default_for_currency":true}
			]}
		}`))
	})
	acct, _ := client.GetAccount("acct_x")
	if acct.DestinationType != "bank" {
		t.Errorf("destination_type=%q, want bank", acct.DestinationType)
	}
	if acct.InstantEligible {
		t.Error("bank destinations are not instant-eligible")
	}
}

func TestCreateTransferSendsIdempotencyKey(t *testing.T) {
	var idemKey string
	var capturedBody url.Values
	_, client := withTestStripe(t, func(w http.ResponseWriter, r *http.Request) {
		idemKey = r.Header.Get("Idempotency-Key")
		body, _ := io.ReadAll(r.Body)
		capturedBody, _ = url.ParseQuery(string(body))
		_, _ = w.Write([]byte(`{"id":"tr_123","amount":1000,"destination":"acct_x","created":1700000000}`))
	})
	tr, err := client.CreateTransfer(CreateTransferParams{
		DestinationAccountID: "acct_x",
		AmountCents:          1000,
		IdempotencyKey:       "wd-tr-uuid",
	})
	if err != nil {
		t.Fatalf("transfer: %v", err)
	}
	if idemKey != "wd-tr-uuid" {
		t.Errorf("idempotency-key = %q", idemKey)
	}
	if tr.ID != "tr_123" {
		t.Errorf("id=%q", tr.ID)
	}
	if capturedBody.Get("amount") != "1000" {
		t.Errorf("amount=%q", capturedBody.Get("amount"))
	}
	if capturedBody.Get("currency") != "usd" {
		t.Errorf("currency=%q", capturedBody.Get("currency"))
	}
	if capturedBody.Get("destination") != "acct_x" {
		t.Errorf("destination=%q", capturedBody.Get("destination"))
	}
}

func TestCreateTransferRequiresParams(t *testing.T) {
	_, client := withTestStripe(t, func(w http.ResponseWriter, r *http.Request) { t.Error("should not call Stripe") })
	_, err := client.CreateTransfer(CreateTransferParams{IdempotencyKey: "x"})
	if err == nil {
		t.Error("expected error for missing destination/amount")
	}
}

func TestCreatePayoutSetsStripeAccountHeader(t *testing.T) {
	var stripeAcct string
	var capturedBody url.Values
	_, client := withTestStripe(t, func(w http.ResponseWriter, r *http.Request) {
		stripeAcct = r.Header.Get("Stripe-Account")
		body, _ := io.ReadAll(r.Body)
		capturedBody, _ = url.ParseQuery(string(body))
		_, _ = w.Write([]byte(`{"id":"po_1","amount":900,"method":"instant","status":"in_transit","arrival_date":1700000300}`))
	})
	po, err := client.CreatePayout(CreatePayoutParams{
		OnBehalfOfAccountID: "acct_user",
		AmountCents:         900,
		Method:              "instant",
		IdempotencyKey:      "wd-po-uuid",
	})
	if err != nil {
		t.Fatalf("payout: %v", err)
	}
	if stripeAcct != "acct_user" {
		t.Errorf("Stripe-Account header = %q", stripeAcct)
	}
	if po.ID != "po_1" || po.Method != "instant" {
		t.Errorf("payout = %+v", po)
	}
	if capturedBody.Get("method") != "instant" {
		t.Errorf("method=%q", capturedBody.Get("method"))
	}
}

func TestCreatePayoutRejectsInvalidMethod(t *testing.T) {
	_, client := withTestStripe(t, func(w http.ResponseWriter, r *http.Request) { t.Error("should not call Stripe") })
	_, err := client.CreatePayout(CreatePayoutParams{
		OnBehalfOfAccountID: "acct_user",
		AmountCents:         100,
		Method:              "ach", // not standard/instant
		IdempotencyKey:      "x",
	})
	if err == nil || !strings.Contains(err.Error(), "invalid payout method") {
		t.Errorf("expected invalid payout method error, got %v", err)
	}
}

func TestMockModeBypassesHTTP(t *testing.T) {
	// No httptest server — mock mode must not hit the network.
	c := NewStripeConnect("", "", "US", true, silentLogger())
	acct, err := c.CreateExpressAccount(CreateExpressAccountParams{Email: "a@b.com"})
	if err != nil {
		t.Fatalf("mock create: %v", err)
	}
	if !strings.HasPrefix(acct.ID, "acct_mock_") {
		t.Errorf("expected mock account id, got %q", acct.ID)
	}
	link, err := c.CreateAccountLink(acct.ID, "https://app/return", "https://app/refresh")
	if err != nil {
		t.Fatalf("mock link: %v", err)
	}
	if !strings.Contains(link, "/setup/mock/") {
		t.Errorf("expected mock link, got %q", link)
	}
	tr, err := c.CreateTransfer(CreateTransferParams{
		DestinationAccountID: acct.ID,
		AmountCents:          100,
		IdempotencyKey:       "x",
	})
	if err != nil {
		t.Fatalf("mock transfer: %v", err)
	}
	if !strings.HasPrefix(tr.ID, "tr_mock_") {
		t.Errorf("expected mock transfer id, got %q", tr.ID)
	}
	po, err := c.CreatePayout(CreatePayoutParams{
		OnBehalfOfAccountID: acct.ID,
		AmountCents:         100,
		Method:              "standard",
		IdempotencyKey:      "x",
	})
	if err != nil {
		t.Fatalf("mock payout: %v", err)
	}
	if !strings.HasPrefix(po.ID, "po_mock_") {
		t.Errorf("expected mock payout id, got %q", po.ID)
	}
}

func TestVerifyConnectWebhookSignatureRejectsEmptySecretInProd(t *testing.T) {
	// Production-shaped client (no mock mode, no webhook secret) must refuse
	// to verify rather than accepting unsigned events.
	c := NewStripeConnect("sk_test", "" /* secret */, "US", false /* mockMode */, silentLogger())
	_, err := c.VerifyConnectWebhookSignature([]byte(`{"type":"x"}`), "")
	if err == nil {
		t.Fatal("expected refusal to verify with empty secret in non-mock mode")
	}
	if !strings.Contains(err.Error(), "webhook secret not configured") {
		t.Errorf("error should mention missing secret; got %v", err)
	}
}

func TestVerifyConnectWebhookSignatureMockModeAllowsUnsigned(t *testing.T) {
	// Mock mode (dev) must still allow unsigned events for local scripting.
	c := NewStripeConnect("", "", "US", true /* mockMode */, silentLogger())
	event, err := c.VerifyConnectWebhookSignature([]byte(`{"type":"account.updated","data":{"object":{"id":"x"}}}`), "")
	if err != nil {
		t.Fatalf("mock mode should allow unsigned events: %v", err)
	}
	if event.Type != "account.updated" {
		t.Errorf("event type = %q", event.Type)
	}
}

func TestVerifyConnectWebhookSignature(t *testing.T) {
	c := NewStripeConnect("sk_test", "whsec_test", "US", false, silentLogger())

	// Use the same StripeProcessor signing helper as the production webhook
	// path uses to verify, so test fixtures stay in lockstep.
	payload := []byte(`{"type":"account.updated","data":{"object":{"id":"acct_x"}}}`)
	tmp := NewStripeProcessor("sk_test", "whsec_test", "", "", silentLogger())
	header := signWebhook(t, tmp, payload)

	event, err := c.VerifyConnectWebhookSignature(payload, header)
	if err != nil {
		t.Fatalf("verify: %v", err)
	}
	if event.Type != "account.updated" {
		t.Errorf("event type = %q", event.Type)
	}

	// Tampered payload should fail.
	tampered := []byte(`{"type":"account.updated","data":{"object":{"id":"acct_y"}}}`)
	if _, err := c.VerifyConnectWebhookSignature(tampered, header); err == nil {
		t.Error("expected signature verification to fail on tampered payload")
	}
}

func TestAccountUpdatedFromEventStatusMapping(t *testing.T) {
	c := NewStripeConnect("sk_test", "", "US", false, silentLogger())

	body := []byte(`{
		"type": "account.updated",
		"data": {
			"object": {
				"id": "acct_x",
				"payouts_enabled": true,
				"details_submitted": true,
				"external_accounts": {"data":[{"object":"card","last4":"1111","funding":"debit","default_for_currency":true}]}
			}
		}
	}`)
	var event WebhookEvent
	if err := json.Unmarshal(body, &event); err != nil {
		t.Fatal(err)
	}
	acct, err := c.AccountUpdatedFromEvent(&event)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if !acct.PayoutsEnabled {
		t.Error("payouts_enabled should be true")
	}
	if !acct.InstantEligible {
		t.Error("instant_eligible should be true for default debit card")
	}
}

func TestPayoutFromEventCapturesFailureFields(t *testing.T) {
	c := NewStripeConnect("sk_test", "", "US", false, silentLogger())
	body := []byte(`{
		"type": "payout.failed",
		"data": {"object": {
			"id": "po_1",
			"status": "failed",
			"amount": 500,
			"method": "standard",
			"failure_code": "account_closed",
			"failure_message": "The bank account was closed."
		}}
	}`)
	var event WebhookEvent
	_ = json.Unmarshal(body, &event)
	pe, err := c.PayoutFromEvent(&event, "acct_x")
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if pe.Status != "failed" {
		t.Errorf("status=%q", pe.Status)
	}
	if pe.FailureCode != "account_closed" {
		t.Errorf("failure_code=%q", pe.FailureCode)
	}
	if pe.FailureReason != "The bank account was closed." {
		t.Errorf("failure_reason=%q", pe.FailureReason)
	}
	if pe.ConnectedAcct != "acct_x" {
		t.Errorf("connected_acct=%q", pe.ConnectedAcct)
	}
}
