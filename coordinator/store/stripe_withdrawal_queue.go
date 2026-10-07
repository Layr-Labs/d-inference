package store

import "time"

const WithdrawalFundingReason = "awaiting_funding"

// Queueing requires a proven rejected transfer, not merely a missing response.
// Claims serialize dispatchers and persist the key generation before a send.
type StripeWithdrawalQueueStore interface {
	QueueStripeWithdrawal(id string, attempt int) error
	// Preflight failures defer an unsent generation without consuming a send.
	DeferStripeWithdrawal(id string, attempt int, now time.Time) error
	// Only an unclaimed queued generation can reject a removed destination.
	RejectQueuedStripeWithdrawal(id string, attempt int, now time.Time, reason string) error
	ClaimStripeWithdrawal(id string, now time.Time) (*StripeWithdrawal, error)
	ListStripeWithdrawalQueue(now time.Time, limit int) ([]StripeWithdrawal, error)
}
