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

type StripeCustomer struct {
	ID    string `json:"id"`
	Email string `json:"email"`
}

type EnterpriseInvoiceRequest struct {
	CustomerID     string
	AccountID      string
	AmountCents    int64
	Currency       string
	Description    string
	PeriodStart    time.Time
	PeriodEnd      time.Time
	TermsDays      int
	Metadata       map[string]string
	IdempotencyKey string
}

type EnterpriseInvoiceResponse struct {
	InvoiceID        string
	Status           string
	HostedInvoiceURL string
	InvoicePDF       string
	DueAt            *time.Time
	SentAt           *time.Time
	AmountDueCents   int64
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

func (p *StripeProcessor) CreateCustomer(email, accountID string) (*StripeCustomer, error) {
	return p.CreateCustomerWithIdempotency(email, accountID, "")
}

func (p *StripeProcessor) CreateCustomerWithIdempotency(email, accountID, idempotencyKey string) (*StripeCustomer, error) {
	form := url.Values{}
	if email != "" {
		form.Set("email", email)
	}
	form.Set("metadata[app]", "darkbloom")
	form.Set("metadata[platform]", "eigeninference")
	form.Set("metadata[account_id]", accountID)
	body, err := p.doStripeForm(http.MethodPost, "/v1/customers", form, idempotencyKey)
	if err != nil {
		return nil, fmt.Errorf("stripe: create customer: %w", err)
	}
	var customer StripeCustomer
	if err := json.Unmarshal(body, &customer); err != nil {
		return nil, fmt.Errorf("stripe: parse customer: %w", err)
	}
	if customer.ID == "" {
		return nil, errors.New("stripe: create customer returned empty id")
	}
	return &customer, nil
}

func (p *StripeProcessor) CreateEnterpriseInvoice(req EnterpriseInvoiceRequest) (*EnterpriseInvoiceResponse, error) {
	if req.Currency == "" {
		req.Currency = "usd"
	}
	if req.CustomerID == "" || req.AmountCents <= 0 {
		return nil, errors.New("stripe: customer_id and amount_cents are required")
	}
	if req.TermsDays < 0 {
		req.TermsDays = 0
	}

	metadata := checkoutMetadata(req.Metadata)
	metadata["purchase_type"] = "enterprise_invoice"
	metadata["account_id"] = req.AccountID

	itemForm := url.Values{}
	itemForm.Set("customer", req.CustomerID)
	itemForm.Set("amount", strconv.FormatInt(req.AmountCents, 10))
	itemForm.Set("currency", req.Currency)
	itemForm.Set("description", req.Description)
	itemForm.Set("period[start]", strconv.FormatInt(req.PeriodStart.Unix(), 10))
	itemForm.Set("period[end]", strconv.FormatInt(req.PeriodEnd.Unix(), 10))
	for k, v := range metadata {
		itemForm.Set("metadata["+k+"]", v)
	}
	if _, err := p.doStripeForm(http.MethodPost, "/v1/invoiceitems", itemForm, req.IdempotencyKey+":item"); err != nil {
		return nil, fmt.Errorf("stripe: create invoice item: %w", err)
	}

	invoiceForm := url.Values{}
	invoiceForm.Set("customer", req.CustomerID)
	invoiceForm.Set("collection_method", "send_invoice")
	invoiceForm.Set("pending_invoice_items_behavior", "include")
	invoiceForm.Set("days_until_due", strconv.Itoa(req.TermsDays))
	invoiceForm.Set("auto_advance", "false")
	invoiceForm.Set("currency", req.Currency)
	for k, v := range metadata {
		invoiceForm.Set("metadata["+k+"]", v)
	}
	body, err := p.doStripeForm(http.MethodPost, "/v1/invoices", invoiceForm, req.IdempotencyKey+":invoice")
	if err != nil {
		return nil, fmt.Errorf("stripe: create invoice: %w", err)
	}
	invoice, err := parseStripeInvoice(body)
	if err != nil {
		return nil, err
	}

	body, err = p.doStripeForm(http.MethodPost, "/v1/invoices/"+invoice.InvoiceID+"/finalize", url.Values{}, req.IdempotencyKey+":finalize")
	if err != nil {
		return nil, fmt.Errorf("stripe: finalize invoice: %w", err)
	}
	invoice, err = parseStripeInvoice(body)
	if err != nil {
		return nil, err
	}

	body, err = p.doStripeForm(http.MethodPost, "/v1/invoices/"+invoice.InvoiceID+"/send", url.Values{}, req.IdempotencyKey+":send")
	if err != nil {
		return nil, fmt.Errorf("stripe: send invoice: %w", err)
	}
	invoice, err = parseStripeInvoice(body)
	if err != nil {
		return nil, err
	}
	return invoice, nil
}

func (p *StripeProcessor) doStripeForm(method, path string, form url.Values, idempotencyKey string) ([]byte, error) {
	httpReq, err := http.NewRequest(method, stripeAPIBase+path, strings.NewReader(form.Encode()))
	if err != nil {
		return nil, fmt.Errorf("build request: %w", err)
	}
	httpReq.Header.Set("Authorization", "Bearer "+p.secretKey)
	httpReq.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	if idempotencyKey != "" {
		httpReq.Header.Set("Idempotency-Key", idempotencyKey)
	}
	resp, err := p.httpClient.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("API request failed: %w", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("read response: %w", err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("API error (status %d): %s", resp.StatusCode, string(body))
	}
	return body, nil
}

func parseStripeInvoice(body []byte) (*EnterpriseInvoiceResponse, error) {
	var raw struct {
		ID                string `json:"id"`
		Status            string `json:"status"`
		HostedInvoiceURL  string `json:"hosted_invoice_url"`
		InvoicePDF        string `json:"invoice_pdf"`
		DueDate           int64  `json:"due_date"`
		StatusTransitions struct {
			FinalizedAt int64 `json:"finalized_at"`
			PaidAt      int64 `json:"paid_at"`
		} `json:"status_transitions"`
		AmountDue int64 `json:"amount_due"`
	}
	if err := json.Unmarshal(body, &raw); err != nil {
		return nil, fmt.Errorf("stripe: parse invoice: %w", err)
	}
	if raw.ID == "" {
		return nil, errors.New("stripe: invoice response missing id")
	}
	var dueAt *time.Time
	if raw.DueDate > 0 {
		t := time.Unix(raw.DueDate, 0)
		dueAt = &t
	}
	var sentAt *time.Time
	if raw.StatusTransitions.FinalizedAt > 0 {
		t := time.Unix(raw.StatusTransitions.FinalizedAt, 0)
		sentAt = &t
	}
	return &EnterpriseInvoiceResponse{
		InvoiceID:        raw.ID,
		Status:           raw.Status,
		HostedInvoiceURL: raw.HostedInvoiceURL,
		InvoicePDF:       raw.InvoicePDF,
		DueAt:            dueAt,
		SentAt:           sentAt,
		AmountDueCents:   raw.AmountDue,
	}, nil
}

func checkoutMetadata(metadata map[string]string) map[string]string {
	params := map[string]string{
		"app":           "darkbloom",
		"platform":      "eigeninference",
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

type InvoiceEvent struct {
	Object struct {
		ID                string            `json:"id"`
		Status            string            `json:"status"`
		HostedInvoiceURL  string            `json:"hosted_invoice_url"`
		InvoicePDF        string            `json:"invoice_pdf"`
		DueDate           int64             `json:"due_date"`
		AmountPaid        int64             `json:"amount_paid"`
		AmountDue         int64             `json:"amount_due"`
		Metadata          map[string]string `json:"metadata"`
		StatusTransitions struct {
			FinalizedAt int64 `json:"finalized_at"`
			PaidAt      int64 `json:"paid_at"`
			VoidedAt    int64 `json:"voided_at"`
		} `json:"status_transitions"`
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

func (p *StripeProcessor) ParseInvoice(event *WebhookEvent) (*InvoiceEvent, error) {
	if event == nil || !strings.HasPrefix(event.Type, "invoice.") {
		return nil, fmt.Errorf("stripe: unexpected event type %q", event.Type)
	}
	var data InvoiceEvent
	if err := json.Unmarshal(event.Data, &data); err != nil {
		return nil, fmt.Errorf("stripe: parse invoice: %w", err)
	}
	if data.Object.ID == "" {
		return nil, errors.New("stripe: invoice missing id")
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
