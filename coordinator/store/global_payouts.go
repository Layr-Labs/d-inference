package store

import (
	"encoding/json"
	"errors"
	"time"
)

var ErrPayoutConflict = errors.New("payout state changed; refresh and try again")
var ErrPayoutQuoteExpired = errors.New("withdrawal quote expired; review a fresh quote")

// GlobalPayoutStore is discovered through As so CachedStore and test wrappers
// preserve access. These tables do not write users or require user-cache invalidation.
type GlobalPayoutStore interface {
	PrepareGlobalRecipient(GlobalRecipient) (*GlobalRecipient, error)
	SaveGlobalRecipient(GlobalRecipient) error
	GetGlobalRecipient(accountID string) (*GlobalRecipient, error)
	RemoveGlobalRecipient(accountID string) error
	CreateGlobalPayoutQuote(GlobalPayout) error
	GetGlobalPayout(id string) (*GlobalPayout, error)
	GetGlobalPayoutByExternalID(id string) (*GlobalPayout, error)
	BeginGlobalPayout(accountID, id string, now time.Time) (*GlobalPayout, error)
	ClaimGlobalPayout(id string, now time.Time) (bool, error)
	ApplyGlobalPayout(id string, result GlobalPayoutResult, now time.Time) error
	ListGlobalPayouts(accountID string, limit int) ([]GlobalPayout, error)
	ListGlobalPayoutsToReconcile(now time.Time, limit int) ([]GlobalPayout, error)
}

type GlobalRecipient struct {
	ID             string `json:"id"` // persistent onboarding generation/idempotency key
	AccountID      string `json:"account_id"`
	Country        string `json:"country"`
	RecipientID    string `json:"recipient_id"`
	PayoutMethodID string `json:"payout_method_id"`
	Last4          string `json:"last4"`
	Ready          bool   `json:"ready"`
}

type GlobalPayout struct {
	DispatchAttempts    int             `json:"dispatch_attempts"`
	ID                  string          `json:"id"`
	AccountID           string          `json:"account_id"`
	RecipientID         string          `json:"recipient_id"`
	RecipientGeneration string          `json:"recipient_generation"`
	PayoutMethodID      string          `json:"payout_method_id"`
	Country             string          `json:"country"`
	AmountMicroUSD      int64           `json:"amount_micro_usd"`
	DestinationAmount   int64           `json:"destination_amount"`
	Currency            string          `json:"currency"`
	Request             json.RawMessage `json:"request"` // immutable request, no API credentials
	Status              string          `json:"status"`  // quoted -> pending -> processing -> posted; or terminal refund
	ExternalID          string          `json:"external_id"`
	FailureCode         string          `json:"failure_code"`
	Refunded            bool            `json:"refunded"`
	ExpiresAt           time.Time       `json:"expires_at"`
	CreatedAt           time.Time       `json:"created_at"`
	SubmittedAt         time.Time       `json:"submitted_at"`
	CheckedAt           time.Time       `json:"checked_at"`
	LeaseUntil          time.Time       `json:"lease_until"`
	Arrival             string          `json:"arrival"`
}
type GlobalPayoutResult struct {
	ExternalID        string
	Status            string
	FailureCode       string
	DestinationAmount int64
	Currency          string
	Arrival           string
}

func cloneGlobalPayout(p GlobalPayout) GlobalPayout {
	p.Request = append(json.RawMessage(nil), p.Request...)
	return p
}
func globalPayoutRefund(status string) bool {
	return status == "failed" || status == "canceled" || status == "returned"
}
func globalPayoutReconcile(p GlobalPayout, now time.Time) bool {
	return (p.Status == "pending" || p.Status == "processing" || (p.Status == "posted" && now.Sub(p.SubmittedAt) < 90*24*time.Hour)) && !p.LeaseUntil.After(now) && now.Sub(p.CheckedAt) >= time.Minute
}

// applyGlobalResult refuses state regression from stale concurrent readbacks.
// A posted payment may return later; already-refunded payments never reopen.
func applyGlobalResult(p *GlobalPayout, r GlobalPayoutResult, now time.Time) (refund bool, err error) {
	if p.Status == "quoted" {
		return false, ErrPayoutConflict
	}
	if r.ExternalID != "" && p.ExternalID != "" && r.ExternalID != p.ExternalID {
		return false, ErrPayoutConflict
	}
	p.CheckedAt = now
	p.LeaseUntil = time.Time{}
	if p.Refunded {
		return false, nil
	}
	if r.ExternalID != "" {
		p.ExternalID = r.ExternalID
	}
	if r.Status == "" {
		p.FailureCode = r.FailureCode
		return false, nil
	}
	if r.Status != "processing" && r.Status != "posted" && !globalPayoutRefund(r.Status) {
		return false, ErrPayoutConflict
	}
	if p.Status == "posted" && r.Status == "processing" {
		return false, nil
	}
	p.Status = r.Status
	p.FailureCode = r.FailureCode
	p.Arrival = r.Arrival
	if r.DestinationAmount > 0 {
		p.DestinationAmount = r.DestinationAmount
		p.Currency = r.Currency
	}
	if globalPayoutRefund(r.Status) {
		p.Refunded = true
		return true, nil
	}
	return false, nil
}

func validateGlobalQuote(p GlobalPayout) error {
	if p.ID == "" || p.AccountID == "" || p.RecipientID == "" || p.RecipientGeneration == "" || p.PayoutMethodID == "" || p.AmountMicroUSD <= 0 || p.AmountMicroUSD%10_000 != 0 || !json.Valid(p.Request) || p.ExpiresAt.IsZero() || p.Status != "quoted" {
		return ErrPayoutConflict
	}
	return nil
}
