package contracts

// BillingStore covers referrals, billing (deposit) sessions, custom per-account
// model pricing, and Stripe Connect withdrawals.
type BillingStore interface {
	ReferralStore
	BillingSessionStore
	ModelPriceStore
	StripeWithdrawalStore
}
