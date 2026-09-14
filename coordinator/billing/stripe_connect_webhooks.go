package billing

import (
	"encoding/json"
	"errors"
	"fmt"
)

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
	Automatic     bool  // true for payouts created by Stripe's payout schedule
	Created       int64 // Unix epoch — when the payout was created (sweeps cover balance available then)
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
			Automatic   bool   `json:"automatic"`
			Created     int64  `json:"created"`
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
		Automatic:     data.Object.Automatic,
		Created:       data.Object.Created,
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
	// Reversed is Stripe's authoritative "fully reversed" flag: it is only
	// true once amount_reversed == amount. Partial reversals fire
	// transfer.reversed events with Reversed=false.
	Reversed bool
	// AmountReversedCents is the cumulative reversed amount across all
	// reversals of this transfer.
	AmountReversedCents int64
}

// TransferFromEvent extracts the transfer object from a charge/transfer event.
func (c *StripeConnect) TransferFromEvent(event *WebhookEvent) (*TransferEvent, error) {
	if event == nil {
		return nil, errors.New("stripe connect: nil event")
	}
	var data struct {
		Object struct {
			ID             string `json:"id"`
			Amount         int64  `json:"amount"`
			AmountReversed int64  `json:"amount_reversed"`
			Destination    string `json:"destination"`
			Reversed       bool   `json:"reversed"`
		} `json:"object"`
	}
	if err := json.Unmarshal(event.Data, &data); err != nil {
		return nil, fmt.Errorf("stripe connect: parse transfer event: %w", err)
	}
	return &TransferEvent{
		ID:                  data.Object.ID,
		AmountCents:         data.Object.Amount,
		AmountReversedCents: data.Object.AmountReversed,
		Destination:         data.Object.Destination,
		Reversed:            data.Object.Reversed,
	}, nil
}
