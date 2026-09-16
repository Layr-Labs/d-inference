package payoutstate

import "github.com/eigeninference/d-inference/coordinator/store/contracts"

type StripeReversalRefund struct {
	Amount    int64
	Reference string
}

func StripeReversalRefunds(wd *contracts.StripeWithdrawal) [2]StripeReversalRefund {
	return [2]StripeReversalRefund{
		{wd.AmountMicroUSD - wd.FeeMicroUSD, "stripe_withdraw:" + wd.ID},
		{wd.FeeMicroUSD, "stripe_withdraw_fee:" + wd.ID},
	}
}
