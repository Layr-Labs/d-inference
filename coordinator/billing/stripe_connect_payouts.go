package billing

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"strconv"
	"time"
)

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
	if err := validAccountID(params.OnBehalfOfAccountID); err != nil {
		return nil, err
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
	return parsePayout(body)
}

// GetPayout fetches a payout's live state from Stripe, authenticated as the
// connected account. Used to confirm an automatic sweep payout is actually
// still "paid" before attributing it to withdrawal rows — webhook delivery
// order is not guaranteed, so a stale payout.paid can arrive after the
// payout already failed.
func (c *StripeConnect) GetPayout(connectedAcctID, payoutID string) (*Payout, error) {
	if c.secretKey == "" && !c.mockMode {
		return nil, errors.New("stripe connect: not configured")
	}
	if connectedAcctID == "" || payoutID == "" {
		return nil, errors.New("stripe connect: account_id and payout_id required")
	}
	if c.mockMode {
		return &Payout{ID: payoutID, Status: "paid"}, nil
	}
	if err := validAccountID(connectedAcctID); err != nil {
		return nil, err
	}
	if !stripePayoutIDRe.MatchString(payoutID) {
		return nil, fmt.Errorf("stripe connect: invalid payout id %q", payoutID)
	}
	body, err := c.do("GET", "/v1/payouts/"+payoutID, nil, "", withStripeAccount(connectedAcctID))
	if err != nil {
		return nil, fmt.Errorf("stripe connect: get payout: %w", err)
	}
	return parsePayout(body)
}

// parsePayout shares the wire projection for payout creation and reconciliation.
func parsePayout(body []byte) (*Payout, error) {
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

// stripePayoutIDRe validates payout IDs before path construction (same
// defense-in-depth as stripeAccountIDRe; IDs come from Stripe webhooks).
var stripePayoutIDRe = regexp.MustCompile(`^po_[A-Za-z0-9_-]{1,128}$`)
