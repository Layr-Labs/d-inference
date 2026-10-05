// Package consumersettlement owns shared consumer charge and referral rules.
package consumersettlement

import (
	"errors"
	"fmt"

	"github.com/eigeninference/d-inference/coordinator/store"
)

type Record struct {
	Input    store.ConsumerChargeSettlement
	Result   store.ConsumerChargeResult
	Referrer string
}

func Validate(in store.ConsumerChargeSettlement) error {
	if in.AccountID == "" || in.JobID == "" {
		return errors.New("store: consumer settlement requires account and job")
	}
	if in.ReservedMicroUSD < 0 || in.CostMicroUSD < 0 {
		return errors.New("store: consumer settlement amounts must not be negative")
	}
	return nil
}

func Replay(in store.ConsumerChargeSettlement, old Record) (store.ConsumerChargeResult, error) {
	if in != old.Input {
		return store.ConsumerChargeResult{}, fmt.Errorf("store: settlement %q already exists with different inputs", in.JobID)
	}
	result := old.Result
	result.Applied = false
	return result, nil
}

// Cost preserves the preflight overage circuit breaker: no more than twice
// the reservation; when available funds cannot cover the extra charge, collect
// only the reservation. Subtraction avoids overflowing 2*reserved.
func Cost(in store.ConsumerChargeSettlement, balance int64) (int64, bool) {
	cost := in.CostMicroUSD
	if in.ReservedMicroUSD > 0 && cost > in.ReservedMicroUSD {
		overage := min(cost-in.ReservedMicroUSD, in.ReservedMicroUSD)
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

// PromotionRecord records only the paid portion. Promotion settlement already
// owns the consumer debit and provider credit; its terminal state fences retries.
func PromotionRecord(r store.ModelTokenReservation, referrer string, referralEligible bool) Record {
	if !referralEligible {
		referrer = ""
	}
	reward := int64(0)
	if referrer != "" {
		reward = r.ConsumerCostMicroUSD / (100 / store.ConsumerReferralPercent)
	}
	return Record{
		Input: store.ConsumerChargeSettlement{AccountID: r.AccountID, JobID: "promotion:" + r.ID,
			ReservedMicroUSD: r.ReservedMicroUSD, CostMicroUSD: r.ConsumerCostMicroUSD, ReferralEnabled: referralEligible},
		Result:   store.ConsumerChargeResult{CollectedMicroUSD: r.ConsumerCostMicroUSD, ReferralRewardMicroUSD: reward, Applied: true},
		Referrer: referrer,
	}
}
