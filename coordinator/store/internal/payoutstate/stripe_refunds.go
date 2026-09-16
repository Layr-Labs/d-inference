package payoutstate

import "github.com/eigeninference/d-inference/coordinator/store/contracts"

// StripeRefund keeps principal and fee credits on their existing ledger references.
type StripeRefund struct {
	Amount    int64
	Reference string
}

func StripeReversalRefunds(wd *contracts.StripeWithdrawal) [2]StripeRefund {
	return [2]StripeRefund{{wd.AmountMicroUSD - wd.FeeMicroUSD, "stripe_withdraw:" + wd.ID}, {wd.FeeMicroUSD, "stripe_withdraw_fee:" + wd.ID}}
}
