package store

import "time"

// BillingSession tracks an in-progress payment via any method (Stripe).
type BillingSession struct {
	ID             string     `json:"id"`
	AccountID      string     `json:"account_id"`
	PaymentMethod  string     `json:"payment_method"` // "stripe"
	AmountMicroUSD int64      `json:"amount_micro_usd"`
	ExternalID     string     `json:"external_id"`   // Stripe session ID, tx hash, etc.
	Status         string     `json:"status"`        // "pending", "completed", "expired"
	ReferralCode   string     `json:"referral_code"` // optional
	CreatedAt      time.Time  `json:"created_at"`
	CompletedAt    *time.Time `json:"completed_at,omitempty"`
}
