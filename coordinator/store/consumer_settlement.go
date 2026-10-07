package store

import "errors"

// ConsumerReferralPercent is funded by Darkbloom independently of provider
// payouts and the platform fee. Amounts use micro-USD and round down per job.
const ConsumerReferralPercent int64 = 5

// ErrReferralConflict identifies duplicate codes, immutable attribution changes, and self-referrals.
var ErrReferralConflict = errors.New("referral conflict")

// ConsumerChargeSettlement finalizes one successful inference request. Reserved
// is money already debited, not an in-memory service-account hold. The caller
// must own the request's reservation finalization lock. Free requests pass zero
// cost, allowing any paid reservation to be refunded without earning a reward.
type ConsumerChargeSettlement struct {
	AccountID        string
	JobID            string
	ReservedMicroUSD int64
	CostMicroUSD     int64
	ReferralEnabled  bool
}

type ConsumerChargeResult struct {
	CollectedMicroUSD      int64
	ReferralRewardMicroUSD int64
	Applied                bool
	Uncollected            bool
}
