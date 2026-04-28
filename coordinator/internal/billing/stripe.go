package billing

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// StripeProcessor handles Stripe Checkout payment sessions.
//
// Flow:
//  1. Consumer calls CreateCheckoutSession with an amount
//  2. Returns a Stripe Checkout URL for the consumer to complete payment
//  3. Stripe sends a webhook (checkout.session.completed) to our endpoint
//  4. We verify the webhook signature and credit the consumer's balance
type StripeProcessor struct {
	secretKey     string
	webhookSecret string
	successURL    string
	cancelURL     string
	logger        *slog.Logger
	httpClient    *http.Client
}

// NewStripeProcessor creates a new Stripe processor.
func NewStripeProcessor(secretKey, webhookSecret, successURL, cancelURL string, logger *slog.Logger) *StripeProcessor {
	return &StripeProcessor{
		secretKey:     secretKey,
		webhookSecret: webhookSecret,
		successURL:    successURL,
		cancelURL:     cancelURL,
		logger:        logger,
		httpClient:    &http.Client{Timeout: 30 * time.Second},
	}
}

// CheckoutSessionRequest is the input for creating a Stripe checkout session.
type CheckoutSessionRequest struct {
	AmountCents   int64             `json:"amount_cents"` // amount in USD cents
	Currency      string            `json:"currency"`     // "usd"
	CustomerEmail string            `json:"customer_email,omitempty"`
	ReferralCode  string            `json:"referral_code,omitempty"`
	Metadata      map[string]string `json:"metadata,omitempty"`
}

// CheckoutSessionResponse is returned after creating a Stripe checkout session.
type CheckoutSessionResponse struct {
	SessionID   string `json:"session_id"`
	URL         string `json:"url"`
	AmountCents int64  `json:"amount_cents"`
}

// CreateCheckoutSession creates a Stripe Checkout Session via the API.
func (p *StripeProcessor) CreateCheckoutSession(req CheckoutSessionRequest) (*CheckoutSessionResponse, error) {
	if req.Currency == "" {
		req.Currency = "usd"
	}
	if req.AmountCents < 50 {
		return nil, errors.New("minimum Stripe charge is $0.50 (50 cents)")
	}

	// Build form-encoded body for Stripe API.
	params := url.Values{}
	params.Set("mode", "payment")
	params.Set("success_url", p.successURL+"?session_id={CHECKOUT_SESSION_ID}")
	params.Set("cancel_url", p.cancelURL)
	params.Set("line_items[0][price_data][currency]", req.Currency)
	params.Set("line_items[0][price_data][product_data][name]", "Darkbloom Inference Credits")
	params.Set("line_items[0][price_data][unit_amount]", strconv.FormatInt(req.AmountCents, 10))
	params.Set("line_items[0][quantity]", "1")
	params.Set("payment_method_types[0]", "card")

	if req.CustomerEmail != "" {
		params.Set("customer_email", req.CustomerEmail)
	}

	// Copy metadata onto both the Checkout Session and underlying PaymentIntent
	// so purchases are identifiable from either Stripe dashboard surface.
	for k, v := range checkoutMetadata(req.Metadata) {
		params.Set("metadata["+k+"]", v)
		params.Set("payment_intent_data[metadata]["+k+"]", v)
	}

	body := params.Encode()

	httpReq, err := http.NewRequest(http.MethodPost, stripeAPIBase+"/v1/checkout/sessions",
		strings.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("stripe: build request: %w", err)
	}
	httpReq.Header.Set("Authorization", "Bearer "+p.secretKey)
	httpReq.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	resp, err := p.httpClient.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("stripe: API request failed: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("stripe: read response: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("stripe: API error (status %d): %s", resp.StatusCode, string(respBody))
	}

	var session struct {
		ID  string `json:"id"`
		URL string `json:"url"`
	}
	if err := json.Unmarshal(respBody, &session); err != nil {
		return nil, fmt.Errorf("stripe: parse response: %w", err)
	}

	return &CheckoutSessionResponse{
		SessionID:   session.ID,
		URL:         session.URL,
		AmountCents: req.AmountCents,
	}, nil
}

func checkoutMetadata(metadata map[string]string) map[string]string {
	params := map[string]string{
		"app":           "darkbloom",
		"platform":      "darkbloom",
		"purchase_type": "inference_credits",
		"source":        "coordinator",
	}
	for k, v := range metadata {
		params[k] = v
	}
	return params
}

// WebhookEvent represents a parsed Stripe webhook event.
type WebhookEvent struct {
	Type string          `json:"type"`
	Data json.RawMessage `json:"data"`
}

// CheckoutSessionEvent is the data from a checkout.session.completed event.
type CheckoutSessionEvent struct {
	Object struct {
		ID            string            `json:"id"`
		AmountTotal   int64             `json:"amount_total"` // in cents
		Currency      string            `json:"currency"`
		PaymentStatus string            `json:"payment_status"` // "paid"
		Metadata      map[string]string `json:"metadata"`
	} `json:"object"`
}

// VerifyWebhookSignature verifies a Stripe webhook signature and returns the parsed event.
// Stripe signs webhooks with HMAC-SHA256 using the webhook signing secret.
//
// Signature header format: t=<timestamp>,v1=<signature>[,v1=<signature>...].
func (p *StripeProcessor) VerifyWebhookSignature(payload []byte, sigHeader string) (*WebhookEvent, error) {
	if p.webhookSecret == "" {
		return nil, errors.New("stripe: webhook secret not configured — refusing to verify")
	}

	// Parse the signature header
	parts := strings.Split(sigHeader, ",")
	var timestamp string
	var signatures []string

	for _, part := range parts {
		kv := strings.SplitN(part, "=", 2)
		if len(kv) != 2 {
			continue
		}
		switch kv[0] {
		case "t":
			timestamp = kv[1]
		case "v1":
			signatures = append(signatures, kv[1])
		}
	}

	if timestamp == "" || len(signatures) == 0 {
		return nil, errors.New("stripe: invalid signature header")
	}

	// Check timestamp tolerance (5 minutes)
	ts, err := strconv.ParseInt(timestamp, 10, 64)
	if err != nil {
		return nil, errors.New("stripe: invalid timestamp in signature")
	}
	if time.Since(time.Unix(ts, 0)) > 5*time.Minute {
		return nil, errors.New("stripe: webhook timestamp too old")
	}

	// Compute expected signature: HMAC-SHA256(timestamp + "." + payload)
	signedPayload := timestamp + "." + string(payload)
	mac := hmac.New(sha256.New, []byte(p.webhookSecret))
	mac.Write([]byte(signedPayload))
	expectedSig := hex.EncodeToString(mac.Sum(nil))

	// Check if any provided signature matches
	valid := false
	for _, sig := range signatures {
		if hmac.Equal([]byte(sig), []byte(expectedSig)) {
			valid = true
			break
		}
	}
	if !valid {
		return nil, errors.New("stripe: webhook signature mismatch")
	}

	var event WebhookEvent
	if err := json.Unmarshal(payload, &event); err != nil {
		return nil, fmt.Errorf("stripe: parse webhook payload: %w", err)
	}

	return &event, nil
}

// ParseCheckoutSession extracts the checkout session data from a webhook event.
func (p *StripeProcessor) ParseCheckoutSession(event *WebhookEvent) (*CheckoutSessionEvent, error) {
	if event.Type != "checkout.session.completed" {
		return nil, fmt.Errorf("stripe: unexpected event type %q", event.Type)
	}

	var data CheckoutSessionEvent
	if err := json.Unmarshal(event.Data, &data); err != nil {
		return nil, fmt.Errorf("stripe: parse checkout session: %w", err)
	}

	if data.Object.PaymentStatus != "paid" {
		return nil, fmt.Errorf("stripe: payment not completed (status: %s)", data.Object.PaymentStatus)
	}

	return &data, nil
}

// RetrieveSession fetches a checkout session from the Stripe API.
func (p *StripeProcessor) RetrieveSession(sessionID string) (*CheckoutSessionEvent, error) {
	httpReq, err := http.NewRequest(http.MethodGet,
		stripeAPIBase+"/v1/checkout/sessions/"+sessionID, nil)
	if err != nil {
		return nil, fmt.Errorf("stripe: build request: %w", err)
	}
	httpReq.Header.Set("Authorization", "Bearer "+p.secretKey)

	resp, err := p.httpClient.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("stripe: API request failed: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("stripe: read response: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("stripe: API error (status %d): %s", resp.StatusCode, string(body))
	}

	var data CheckoutSessionEvent
	data.Object.ID = sessionID
	if err := json.Unmarshal(body, &data.Object); err != nil {
		return nil, fmt.Errorf("stripe: parse session: %w", err)
	}

	return &data, nil
}
