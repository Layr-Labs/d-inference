package store

import (
	"errors"
	"fmt"
)

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

type consumerSettlementRecord struct {
	Input    ConsumerChargeSettlement
	Result   ConsumerChargeResult
	Referrer string
}

func validateConsumerSettlement(in ConsumerChargeSettlement) error {
	if in.AccountID == "" || in.JobID == "" {
		return errors.New("store: consumer settlement requires account and job")
	}
	if in.ReservedMicroUSD < 0 || in.CostMicroUSD < 0 {
		return errors.New("store: consumer settlement amounts must not be negative")
	}
	return nil
}

func replayConsumerSettlement(in ConsumerChargeSettlement, old consumerSettlementRecord) (ConsumerChargeResult, error) {
	if in != old.Input {
		return ConsumerChargeResult{}, fmt.Errorf("store: settlement %q already exists with different inputs", in.JobID)
	}
	result := old.Result
	result.Applied = false
	return result, nil
}

// settlementCost preserves the preflight overage circuit breaker: no more than
// twice the reservation; when available funds cannot cover the extra charge,
// collect only the reservation. Without a reservation an unaffordable charge
// collects nothing. Subtraction avoids overflowing 2*reserved.
func settlementCost(in ConsumerChargeSettlement, balance int64) (int64, bool) {
	cost := in.CostMicroUSD
	if in.ReservedMicroUSD > 0 && cost > in.ReservedMicroUSD {
		overage := cost - in.ReservedMicroUSD
		if overage > in.ReservedMicroUSD {
			overage = in.ReservedMicroUSD
		}
		if balance < overage {
			return in.ReservedMicroUSD, false
		}
		return in.ReservedMicroUSD + overage, false
	}
	if in.ReservedMicroUSD == 0 && balance < cost {
		return 0, true
	}
	return cost, false
}
