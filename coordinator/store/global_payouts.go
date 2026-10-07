package store

import (
	"encoding/json"
	"errors"
	"time"
)

var ErrPayoutConflict = errors.New("payout state changed; refresh and try again")

var ErrPayoutQuoteExpired = errors.New("withdrawal quote expired; review a fresh quote")

const GlobalPayoutManualReview = "manual_reconciliation_required"

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
	ExpireGlobalPayoutQuote(accountID, id string, now time.Time) (*GlobalPayout, error)
	BeginGlobalPayout(accountID, id string, now time.Time) (*GlobalPayout, error)
	ClaimGlobalPayout(id string, now time.Time) (*GlobalPayout, error)
	StartGlobalPayoutDispatch(id string, leaseUntil, now time.Time) error
	StartUnsentGlobalPayout(id string, leaseUntil time.Time, request json.RawMessage, fees json.RawMessage, destinationAmount int64, expiresAt, now time.Time) error
	RecordGlobalPayoutRejection(id string, attempt int, code string, leaseUntil time.Time) error
	ApplyGlobalPayout(id string, result GlobalPayoutResult, now time.Time) error
	PruneExpiredGlobalPayoutQuotes(now time.Time, limit int) (int64, error)
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
	QuoteInvalidated    bool                   `json:"quote_invalidated,omitempty"`
	EstimatedStripeFees json.RawMessage        `json:"estimated_stripe_fees,omitempty"`
	FundingGeneration   int                    `json:"funding_generation,omitempty"`
	DispatchStartedAt   time.Time              `json:"dispatch_started_at,omitempty"`
	DispatchAttempts    int                    `json:"dispatch_attempts"`
	Rejection           *GlobalPayoutRejection `json:"rejection,omitempty"`
	ID                  string                 `json:"id"`
	AccountID           string                 `json:"account_id"`
	RecipientID         string                 `json:"recipient_id"`
	RecipientGeneration string                 `json:"recipient_generation"`
	PayoutMethodID      string                 `json:"payout_method_id"`
	Country             string                 `json:"country"`
	AmountMicroUSD      int64                  `json:"amount_micro_usd"`
	DestinationAmount   int64                  `json:"destination_amount"`
	Currency            string                 `json:"currency"`
	Request             json.RawMessage        `json:"request"` // frozen once dispatched; queued requests may refresh their quote
	Status              string                 `json:"status"`  // quoted -> pending/queued -> processing -> posted; or terminal refund
	ExternalID          string                 `json:"external_id"`
	FailureCode         string                 `json:"failure_code"`
	Refunded            bool                   `json:"refunded"`
	ExpiresAt           time.Time              `json:"expires_at"`
	CreatedAt           time.Time              `json:"created_at"`
	SubmittedAt         time.Time              `json:"submitted_at"`
	CheckedAt           time.Time              `json:"checked_at"`
	LeaseUntil          time.Time              `json:"lease_until"`
	Arrival             string                 `json:"arrival"`
}

// GlobalPayoutRejection is recorded before the refund transaction, so a failed
// refund write never causes another send or discards the definitive rejection.
type GlobalPayoutRejection struct {
	Attempt int    `json:"attempt"`
	Code    string `json:"code"`
}

type GlobalPayoutResult struct {
	ExpectedLease     time.Time // nonzero fences a delayed reconciler against a newer claim
	ExternalID        string
	Status            string
	FailureCode       string
	DestinationAmount int64
	Currency          string
	Arrival           string
}

// RequiresManualReconciliation parks unknown outcomes without refunding them.
// Attaching a verified external payment ID permits readback reconciliation again.
func (p GlobalPayout) RequiresManualReconciliation() bool {
	return p.ExternalID == "" && p.Rejection == nil && p.FailureCode == GlobalPayoutManualReview
}

// ReconciliationWindowStart excludes the funding wait from posted-payment
// protection. Historical payments without a dispatch timestamp use confirmation.
func (p GlobalPayout) ReconciliationWindowStart() time.Time {
	if !p.DispatchStartedAt.IsZero() {
		return p.DispatchStartedAt
	}
	return p.SubmittedAt
}
