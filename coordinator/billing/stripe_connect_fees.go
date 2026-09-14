package billing

import ()

// InstantFeeBps is the fee charged on Instant Payout withdrawals, in basis
// points (150 bps = 1.5%). Calls to FeeForInstantPayoutMicroUSD use this.
const InstantFeeBps int64 = 150

// InstantFeeMinMicroUSD is the floor of the Instant Payout fee. With a 1.5%
// rate this kicks in below ~$33.33.
const InstantFeeMinMicroUSD int64 = 500_000 // $0.50

// MinWithdrawMicroUSD is the smallest withdrawal accepted on the Stripe rail.
// $1 lines up with Stripe's ACH minimum.
const MinWithdrawMicroUSD int64 = 1_000_000

// FeeForInstantPayoutMicroUSD computes the platform fee for an instant payout
// of the given gross amount. Standard payouts return 0.
func FeeForInstantPayoutMicroUSD(grossMicroUSD int64) int64 {
	if grossMicroUSD <= 0 {
		return 0
	}
	pct := grossMicroUSD * InstantFeeBps / 10_000 // basis points → fraction
	if pct < InstantFeeMinMicroUSD {
		return InstantFeeMinMicroUSD
	}
	return pct
}

// FeeForMethodMicroUSD returns the per-withdrawal fee for the given method.
// Standard ACH is free to the user; Instant uses FeeForInstantPayoutMicroUSD.
func FeeForMethodMicroUSD(method string, grossMicroUSD int64) int64 {
	if method == "instant" {
		return FeeForInstantPayoutMicroUSD(grossMicroUSD)
	}
	return 0
}
