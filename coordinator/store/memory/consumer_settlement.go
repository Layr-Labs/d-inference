package memory

import (
	"errors"
	"math"

	"github.com/eigeninference/d-inference/coordinator/internal/store/consumersettlement"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// FinalizeConsumerCharge commits the charge and referral reward under one lock.
// A retry cannot debit, refund, or reward a job twice.
func (s *MemoryStore) FinalizeConsumerCharge(in store.ConsumerChargeSettlement) (store.ConsumerChargeResult, error) {
	if err := consumersettlement.Validate(in); err != nil {
		return store.ConsumerChargeResult{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if old, ok := s.consumerSettlements[in.JobID]; ok {
		return consumersettlement.Replay(in, old)
	}
	collected, uncollected := consumersettlement.Cost(in, s.balances[in.AccountID])
	referrer := ""
	if in.ReferralEnabled {
		if ref := s.referrersByCode[s.referrals[in.AccountID]]; ref != nil && ref.AccountID != in.AccountID {
			referrer = ref.AccountID
		}
	}
	reward := int64(0)
	if referrer != "" {
		reward = collected / (100 / store.ConsumerReferralPercent)
	}
	delta := collected - in.ReservedMicroUSD
	if (delta < 0 && s.balances[in.AccountID] > math.MaxInt64+delta) ||
		(reward > 0 && (s.balances[referrer] > math.MaxInt64-reward || s.withdrawable[referrer] > math.MaxInt64-reward)) {
		return store.ConsumerChargeResult{}, errors.New("store: consumer settlement balance overflow")
	}
	if delta < 0 {
		s.creditLocked(in.AccountID, -delta, store.LedgerRefund, in.JobID, s.now())
	} else if delta > 0 {
		reference := in.JobID
		if in.ReservedMicroUSD > 0 {
			reference = "overage:" + in.JobID
		}
		if err := s.debitLocked(in.AccountID, delta, store.LedgerCharge, reference); err != nil {
			return store.ConsumerChargeResult{}, err
		}
	}
	if reward > 0 {
		s.creditLocked(referrer, reward, store.LedgerReferralReward, in.JobID, s.now())
		s.withdrawable[referrer] += reward
	}
	result := store.ConsumerChargeResult{CollectedMicroUSD: collected, ReferralRewardMicroUSD: reward, Applied: true, Uncollected: uncollected}
	s.consumerSettlements[in.JobID] = consumersettlement.Record{Input: in, Result: result, Referrer: referrer}
	return result, nil
}
