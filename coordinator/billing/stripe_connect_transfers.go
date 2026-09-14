package billing

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strconv"
	"time"
)

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
