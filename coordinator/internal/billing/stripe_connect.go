package billing

import (
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

// Stripe Connect Express integration for paying users out to bank accounts and
// debit cards.
//
// Lifecycle:
//
//  1. We create an Express connected account (`accounts.create`) for the user
//     when they click "Withdraw to bank" — `CreateExpressAccount`.
//  2. We hand them a hosted onboarding link (`account_links.create`) — Stripe
//     handles KYC, bank/card linking, and tax form collection — `CreateAccountLink`.
//  3. The `account.updated` webhook tells us when `payouts_enabled=true` — we
//     parse the event with `ParseAccountFromRaw` and the user's account is then
//     "ready".
//  4. To withdraw, we move USD from the platform balance to the connected
//     account (`transfers.create` — `CreateTransfer`), then trigger a payout
//     to bank or debit card (`payouts.create` — `CreatePayout`).
//  5. Webhook events `payout.paid`, `payout.failed`, `transfer.failed` drive
//     the local withdrawal state machine; on terminal failure we re-credit the
//     user's ledger.
//
// All amounts cross the Stripe boundary in **integer USD cents**. The internal
// micro-USD ledger has six-decimal precision; we always lose precision below a
// cent on the way out. Callers must compute the exact debit-vs-fee split in
// micro-USD and pass cent-rounded values here.

// InstantFeeBps is the fee charged on Instant Payout withdrawals, in basis
// points (150 bps = 1.5%). Calls to FeeForInstantPayoutMicroUSD use this.
const InstantFeeBps int64 = 150

// InstantFeeMinMicroUSD is the floor of the Instant Payout fee. With a 1.5%
// rate this kicks in below ~$33.33.
const InstantFeeMinMicroUSD int64 = 500_000 // $0.50

// MinWithdrawMicroUSD is the smallest withdrawal accepted on the Stripe rail.
// $1 lines up with both Stripe's ACH minimum and the Solana withdraw minimum.
const MinWithdrawMicroUSD int64 = 1_000_000

// FeeForInstantPayoutMicroUSD computes the platform fee for an instant payout
// of the given gross amount. Standard payouts return 0.
func FeeForInstantPayoutMicroUSD(grossMicroUSD int64) int64 {
	if grossMicroUSD <= 0 {
		return 0
	}
	pct := grossMicroUSD * InstantFeeBps / 10_000 // basis points → fraction
	if pct < InstantFeeMinMicroUSD {
		return InstantFeeMinMicroUSD
	}
	return pct
}

// FeeForMethodMicroUSD returns the per-withdrawal fee for the given method.
// Standard ACH is free to the user; Instant uses FeeForInstantPayoutMicroUSD.
func FeeForMethodMicroUSD(method string, grossMicroUSD int64) int64 {
	if method == "instant" {
		return FeeForInstantPayoutMicroUSD(grossMicroUSD)
	}
	return 0
}

// StripeConnect wraps the Stripe Connect Express endpoints. It piggybacks on
// the same secret key + HTTP client as StripeProcessor.
type StripeConnect struct {
	secretKey            string
	connectWebhookSecret string
	platformCountry      string // ISO 3166-1 alpha-2 — defaults to "US"
	mockMode             bool   // skips real Stripe API calls; returns deterministic stub responses
	httpClient           *http.Client
	logger               *slog.Logger
}

// NewStripeConnect builds a Stripe Connect client. If secretKey is empty the
// client returns errors from every method; the higher-level service treats
// that as "Stripe Payouts not configured".
func NewStripeConnect(secretKey, connectWebhookSecret, platformCountry string, mockMode bool, logger *slog.Logger) *StripeConnect {
	if platformCountry == "" {
		platformCountry = "US"
	}
	return &StripeConnect{
		secretKey:            secretKey,
		connectWebhookSecret: connectWebhookSecret,
		platformCountry:      platformCountry,
		mockMode:             mockMode,
		httpClient:           &http.Client{Timeout: 30 * time.Second},
		logger:               logger,
	}
}

// MockMode reports whether the client is short-circuiting Stripe API calls.
func (c *StripeConnect) MockMode() bool { return c.mockMode }

// stripeAPIBase is overridden by tests to point at httptest.NewServer().
var stripeAPIBase = "https://api.stripe.com"

// SetStripeAPIBaseForTest swaps the Stripe API base URL and returns the
// previous value so the caller can restore it. Test-only helper — production
// code must never call this.
func SetStripeAPIBaseForTest(url string) string {
	prev := stripeAPIBase
	stripeAPIBase = url
	return prev
}

// ExpressAccount captures the subset of fields we care about on a Stripe
// connected account.
type ExpressAccount struct {
	ID               string
	Email            string
	ChargesEnabled   bool
	PayoutsEnabled   bool
	DetailsSubmitted bool
	CurrentlyDue     []string // requirements blocking the account from being live
	DisabledReason   string   // populated when Stripe permanently disables the account
	DestinationType  string   // "bank" | "card" | ""
	DestinationLast4 string
	DestinationCard  string // brand for cards (e.g. "visa")
	InstantEligible  bool   // debit card destination supports Instant Payouts
}

// CreateExpressAccountParams gates which prefilled fields we pass to Stripe on
// account creation. Email/first/last come from Privy; country defaults to US.
type CreateExpressAccountParams struct {
	Email     string
	FirstName string
	LastName  string
	Country   string // ISO 3166-1 alpha-2 — empty means "use platform default"
}

// CreateExpressAccount creates a Stripe Express connected account. We request
// both `transfers` (to push funds out) and `card_payments` because Stripe's
// Connect Express flow requires the latter unless the platform has been
// pre-approved for transfers-only. Requesting `card_payments` doesn't mean
// we ever charge cards on behalf of the user — the capability just sits
// enabled on the connected account; we only ever call transfers + payouts.
// The trade-off is slightly more KYC info collected during onboarding, which
// the user fills in on Stripe's hosted page anyway.
func (c *StripeConnect) CreateExpressAccount(params CreateExpressAccountParams) (*ExpressAccount, error) {
	if c.secretKey == "" && !c.mockMode {
		return nil, errors.New("stripe connect: not configured")
	}
	country := params.Country
	if country == "" {
		country = c.platformCountry
	}

	if c.mockMode {
		mockID := "acct_mock_" + strings.ReplaceAll(params.Email, "@", "_at_")
		return &ExpressAccount{
			ID:               mockID,
			Email:            params.Email,
			ChargesEnabled:   false,
			PayoutsEnabled:   false,
			DetailsSubmitted: false,
		}, nil
	}

	form := url.Values{}
	form.Set("type", "express")
	form.Set("country", country)
	form.Set("capabilities[transfers][requested]", "true")
	form.Set("capabilities[card_payments][requested]", "true")
	form.Set("business_type", "individual")
	if params.Email != "" {
		form.Set("email", params.Email)
		form.Set("individual[email]", params.Email)
	}
	if params.FirstName != "" {
		form.Set("individual[first_name]", params.FirstName)
	}
	if params.LastName != "" {
		form.Set("individual[last_name]", params.LastName)
	}
	// We hand off all subsequent collection to Stripe's hosted flow.
	form.Set("settings[payouts][schedule][interval]", "manual")

	body, err := c.do("POST", "/v1/accounts", form, "")
	if err != nil {
		return nil, fmt.Errorf("stripe connect: create account: %w", err)
	}
	return parseAccount(body)
}

// CreateAccountLink returns a hosted onboarding URL the frontend should
// redirect to. Stripe handles the KYC + bank linking flow.
func (c *StripeConnect) CreateAccountLink(accountID, returnURL, refreshURL string) (string, error) {
	if c.secretKey == "" && !c.mockMode {
		return "", errors.New("stripe connect: not configured")
	}
	if accountID == "" || returnURL == "" || refreshURL == "" {
		return "", errors.New("stripe connect: account_id, return_url, refresh_url required")
	}

	if c.mockMode {
		return "https://connect.stripe.com/setup/mock/" + accountID + "?return=" + url.QueryEscape(returnURL), nil
	}

	form := url.Values{}
	form.Set("account", accountID)
	form.Set("type", "account_onboarding")
	form.Set("return_url", returnURL)
	form.Set("refresh_url", refreshURL)
	form.Set("collect", "eventually_due")

	body, err := c.do("POST", "/v1/account_links", form, "")
	if err != nil {
		return "", fmt.Errorf("stripe connect: create account link: %w", err)
	}
	var resp struct {
		URL string `json:"url"`
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		return "", fmt.Errorf("stripe connect: parse account link: %w", err)
	}
	return resp.URL, nil
}

// GetAccount fetches the latest account state from Stripe. We use this when the
// user lands back on the billing page after onboarding so we can render the
// "ready" / "needs more info" state without waiting for the webhook.
func (c *StripeConnect) GetAccount(accountID string) (*ExpressAccount, error) {
	if c.secretKey == "" && !c.mockMode {
		return nil, errors.New("stripe connect: not configured")
	}
	if accountID == "" {
		return nil, errors.New("stripe connect: account_id required")
	}

	if c.mockMode {
		// Mock-mode account is "ready" so devs can exercise withdrawals.
		return &ExpressAccount{
			ID:               accountID,
			ChargesEnabled:   true,
			PayoutsEnabled:   true,
			DetailsSubmitted: true,
			DestinationType:  "bank",
			DestinationLast4: "4242",
		}, nil
	}

	body, err := c.do("GET", "/v1/accounts/"+accountID, nil, "")
	if err != nil {
		return nil, fmt.Errorf("stripe connect: get account: %w", err)
	}
	return parseAccount(body)
}

// CreateTransferParams describes a transfer from the platform balance into a
// connected account's balance. amountCents is the integer-cent amount net of
// any user-facing fee.
type CreateTransferParams struct {
	DestinationAccountID string
	AmountCents          int64
	IdempotencyKey       string
	Description          string // optional, surfaced in the Stripe dashboard
}

// Transfer is the small subset of Stripe Transfer fields we need.
type Transfer struct {
	ID          string
	AmountCents int64
	Destination string
	Created     int64
}

// CreateTransfer pushes USD from the platform balance to the connected account.
// Always wrap the call in an idempotency key so a retry after a network blip
// can't double-pay the user.
func (c *StripeConnect) CreateTransfer(params CreateTransferParams) (*Transfer, error) {
	if c.secretKey == "" && !c.mockMode {
		return nil, errors.New("stripe connect: not configured")
	}
	if params.DestinationAccountID == "" || params.AmountCents <= 0 || params.IdempotencyKey == "" {
		return nil, errors.New("stripe connect: destination, amount_cents>0, idempotency_key required")
	}

	if c.mockMode {
		return &Transfer{
			ID:          "tr_mock_" + params.IdempotencyKey,
			AmountCents: params.AmountCents,
			Destination: params.DestinationAccountID,
			Created:     time.Now().Unix(),
		}, nil
	}

	form := url.Values{}
	form.Set("amount", strconv.FormatInt(params.AmountCents, 10))
	form.Set("currency", "usd")
	form.Set("destination", params.DestinationAccountID)
	if params.Description != "" {
		form.Set("description", params.Description)
	}

	body, err := c.do("POST", "/v1/transfers", form, params.IdempotencyKey)
	if err != nil {
		return nil, fmt.Errorf("stripe connect: create transfer: %w", err)
	}

	var resp struct {
		ID          string `json:"id"`
		Amount      int64  `json:"amount"`
		Destination string `json:"destination"`
		Created     int64  `json:"created"`
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		return nil, fmt.Errorf("stripe connect: parse transfer: %w", err)
	}
	return &Transfer{
		ID:          resp.ID,
		AmountCents: resp.Amount,
		Destination: resp.Destination,
		Created:     resp.Created,
	}, nil
}

// CreatePayoutParams describes a payout from a connected account's balance to
// the user's external bank account or debit card. Method is "standard" or
// "instant"; instant only works against eligible debit-card destinations.
type CreatePayoutParams struct {
	OnBehalfOfAccountID string
	AmountCents         int64
	Method              string // "standard" | "instant"
	IdempotencyKey      string
	Description         string
}

// Payout captures the Stripe Payout fields we surface to the user.
type Payout struct {
	ID          string
	AmountCents int64
	Method      string
	Status      string
	ArrivalDate int64 // Unix epoch — when funds are expected to land
}

// CreatePayout instructs the connected account to pay out to its external
// destination. The Stripe-Account header authenticates the call as the
// connected account so the payout draws from their balance, not ours.
func (c *StripeConnect) CreatePayout(params CreatePayoutParams) (*Payout, error) {
	if c.secretKey == "" && !c.mockMode {
		return nil, errors.New("stripe connect: not configured")
	}
	if params.OnBehalfOfAccountID == "" || params.AmountCents <= 0 || params.IdempotencyKey == "" {
		return nil, errors.New("stripe connect: account, amount_cents>0, idempotency_key required")
	}
	method := params.Method
	if method == "" {
		method = "standard"
	}
	if method != "standard" && method != "instant" {
		return nil, fmt.Errorf("stripe connect: invalid payout method %q", method)
	}

	if c.mockMode {
		return &Payout{
			ID:          "po_mock_" + params.IdempotencyKey,
			AmountCents: params.AmountCents,
			Method:      method,
			Status:      "in_transit",
			ArrivalDate: time.Now().Add(24 * time.Hour).Unix(),
		}, nil
	}

	form := url.Values{}
	form.Set("amount", strconv.FormatInt(params.AmountCents, 10))
	form.Set("currency", "usd")
	form.Set("method", method)
	if params.Description != "" {
		form.Set("description", params.Description)
	}

	body, err := c.do("POST", "/v1/payouts", form, params.IdempotencyKey, withStripeAccount(params.OnBehalfOfAccountID))
	if err != nil {
		return nil, fmt.Errorf("stripe connect: create payout: %w", err)
	}
	var resp struct {
		ID          string `json:"id"`
		Amount      int64  `json:"amount"`
		Method      string `json:"method"`
		Status      string `json:"status"`
		ArrivalDate int64  `json:"arrival_date"`
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		return nil, fmt.Errorf("stripe connect: parse payout: %w", err)
	}
	return &Payout{
		ID:          resp.ID,
		AmountCents: resp.Amount,
		Method:      resp.Method,
		Status:      resp.Status,
		ArrivalDate: resp.ArrivalDate,
	}, nil
}

// VerifyConnectWebhookSignature mirrors StripeProcessor.VerifyWebhookSignature
// but uses the Connect-specific webhook secret. Stripe sends Connect events to
// a separate endpoint configured in the dashboard with its own signing secret.
//
// In production we hard-fail if the secret isn't configured: webhooks drive
// ledger refunds, so accepting unsigned events would let a stolen payout ID
// trigger a refund. Mock mode (dev) parses without verification so test
// scripts can drive the state machine end-to-end.
func (c *StripeConnect) VerifyConnectWebhookSignature(payload []byte, sigHeader string) (*WebhookEvent, error) {
	if c.connectWebhookSecret == "" {
		if !c.mockMode {
			return nil, errors.New("stripe connect: webhook secret not configured — refusing to verify")
		}
		// Mock-only fallback so dev tooling can post events.
		var event WebhookEvent
		if err := json.Unmarshal(payload, &event); err != nil {
			return nil, fmt.Errorf("stripe connect: parse webhook: %w", err)
		}
		return &event, nil
	}

	// Reuse the StripeProcessor signature path by constructing an ad-hoc one
	// with the same secret. Keeps the HMAC code in one place.
	tmp := &StripeProcessor{webhookSecret: c.connectWebhookSecret}
	return tmp.VerifyWebhookSignature(payload, sigHeader)
}

// AccountUpdatedFromEvent extracts the Stripe Account fields we mirror locally.
func (c *StripeConnect) AccountUpdatedFromEvent(event *WebhookEvent) (*ExpressAccount, error) {
	if event == nil || event.Type != "account.updated" {
		return nil, fmt.Errorf("stripe connect: expected account.updated, got %q", event.Type)
	}
	var data struct {
		Object json.RawMessage `json:"object"`
	}
	if err := json.Unmarshal(event.Data, &data); err != nil {
		return nil, fmt.Errorf("stripe connect: parse account.updated: %w", err)
	}
	return parseAccount(data.Object)
}

// PayoutEvent captures the subset of payout fields driven by webhooks.
type PayoutEvent struct {
	ID            string
	Status        string // "paid" | "failed" | etc
	AmountCents   int64
	Method        string
	FailureCode   string
	FailureReason string
	Destination   string // pm-style ID (ba_… / card_…)
	ConnectedAcct string // Stripe-Account header value, populated from event.Account
}

// PayoutFromEvent extracts the Payout fields we need, plus the connected
// account ID from the event envelope (Stripe sends Connect-account events with
// an "account" field at the top level).
func (c *StripeConnect) PayoutFromEvent(event *WebhookEvent, rawAccount string) (*PayoutEvent, error) {
	if event == nil {
		return nil, errors.New("stripe connect: nil event")
	}
	var data struct {
		Object struct {
			ID          string `json:"id"`
			Status      string `json:"status"`
			Amount      int64  `json:"amount"`
			Method      string `json:"method"`
			FailureCode string `json:"failure_code"`
			FailureMsg  string `json:"failure_message"`
			Destination string `json:"destination"`
		} `json:"object"`
	}
	if err := json.Unmarshal(event.Data, &data); err != nil {
		return nil, fmt.Errorf("stripe connect: parse payout event: %w", err)
	}
	return &PayoutEvent{
		ID:            data.Object.ID,
		Status:        data.Object.Status,
		AmountCents:   data.Object.Amount,
		Method:        data.Object.Method,
		FailureCode:   data.Object.FailureCode,
		FailureReason: data.Object.FailureMsg,
		Destination:   data.Object.Destination,
		ConnectedAcct: rawAccount,
	}, nil
}

// TransferEvent is the slimmed-down view of a transfer-related event.
type TransferEvent struct {
	ID          string
	AmountCents int64
	Destination string
	Reversed    bool
}

// TransferFromEvent extracts the transfer object from a charge/transfer event.
func (c *StripeConnect) TransferFromEvent(event *WebhookEvent) (*TransferEvent, error) {
	if event == nil {
		return nil, errors.New("stripe connect: nil event")
	}
	var data struct {
		Object struct {
			ID          string `json:"id"`
			Amount      int64  `json:"amount"`
			Destination string `json:"destination"`
			Reversed    bool   `json:"reversed"`
		} `json:"object"`
	}
	if err := json.Unmarshal(event.Data, &data); err != nil {
		return nil, fmt.Errorf("stripe connect: parse transfer event: %w", err)
	}
	return &TransferEvent{
		ID:          data.Object.ID,
		AmountCents: data.Object.Amount,
		Destination: data.Object.Destination,
		Reversed:    data.Object.Reversed,
	}, nil
}

// --- HTTP plumbing ---

type doOption func(req *http.Request)

func withStripeAccount(acct string) doOption {
	return func(req *http.Request) {
		if acct != "" {
			req.Header.Set("Stripe-Account", acct)
		}
	}
}

func (c *StripeConnect) do(method, path string, form url.Values, idempotencyKey string, opts ...doOption) ([]byte, error) {
	var body io.Reader
	if form != nil {
		body = strings.NewReader(form.Encode())
	}
	req, err := http.NewRequest(method, stripeAPIBase+path, body)
	if err != nil {
		return nil, fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+c.secretKey)
	if form != nil {
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	if idempotencyKey != "" {
		req.Header.Set("Idempotency-Key", idempotencyKey)
	}
	for _, opt := range opts {
		opt(req)
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("api request: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("read response: %w", err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		// Try to surface Stripe's structured error message verbatim.
		var errEnvelope struct {
			Error struct {
				Message string `json:"message"`
				Type    string `json:"type"`
				Code    string `json:"code"`
			} `json:"error"`
		}
		if json.Unmarshal(respBody, &errEnvelope) == nil && errEnvelope.Error.Message != "" {
			return nil, fmt.Errorf("stripe %d: %s", resp.StatusCode, errEnvelope.Error.Message)
		}
		return nil, fmt.Errorf("stripe %d: %s", resp.StatusCode, string(respBody))
	}
	return respBody, nil
}

// parseAccount maps the raw account JSON onto our trimmed ExpressAccount type.
// It pulls the destination (bank account or debit card) from external_accounts
// when present so the UI can show "Chase ••4821".
func parseAccount(body []byte) (*ExpressAccount, error) {
	var resp struct {
		ID               string `json:"id"`
		Email            string `json:"email"`
		ChargesEnabled   bool   `json:"charges_enabled"`
		PayoutsEnabled   bool   `json:"payouts_enabled"`
		DetailsSubmitted bool   `json:"details_submitted"`
		Requirements     struct {
			CurrentlyDue   []string `json:"currently_due"`
			DisabledReason string   `json:"disabled_reason"`
		} `json:"requirements"`
		ExternalAccounts struct {
			Data []struct {
				Object             string `json:"object"` // "bank_account" | "card"
				Last4              string `json:"last4"`
				Brand              string `json:"brand"`
				Funding            string `json:"funding"`
				DefaultForCurrency bool   `json:"default_for_currency"`
			} `json:"data"`
		} `json:"external_accounts"`
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		return nil, fmt.Errorf("parse account: %w", err)
	}

	acct := &ExpressAccount{
		ID:               resp.ID,
		Email:            resp.Email,
		ChargesEnabled:   resp.ChargesEnabled,
		PayoutsEnabled:   resp.PayoutsEnabled,
		DetailsSubmitted: resp.DetailsSubmitted,
		CurrentlyDue:     resp.Requirements.CurrentlyDue,
		DisabledReason:   resp.Requirements.DisabledReason,
	}

	// Pick the default external account (or the first one) as the destination
	// we display. Instant Payouts only work against debit cards.
	var pick *struct {
		Object             string `json:"object"`
		Last4              string `json:"last4"`
		Brand              string `json:"brand"`
		Funding            string `json:"funding"`
		DefaultForCurrency bool   `json:"default_for_currency"`
	}
	for i := range resp.ExternalAccounts.Data {
		ea := &resp.ExternalAccounts.Data[i]
		if pick == nil || ea.DefaultForCurrency {
			pick = ea
		}
		if ea.DefaultForCurrency {
			break
		}
	}
	if pick != nil {
		switch pick.Object {
		case "bank_account":
			acct.DestinationType = "bank"
		case "card":
			acct.DestinationType = "card"
			acct.DestinationCard = pick.Brand
			// Stripe only supports Instant Payouts to debit cards.
			if strings.EqualFold(pick.Funding, "debit") {
				acct.InstantEligible = true
			}
		}
		acct.DestinationLast4 = pick.Last4
	}
	return acct, nil
}
