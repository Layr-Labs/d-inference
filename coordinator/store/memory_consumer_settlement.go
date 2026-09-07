package store

import (
	"errors"
	"math"
	"time"
)

// FinalizeConsumerCharge commits consumer settlement and the referral reward
// under one lock. A retry cannot debit, refund, or reward a job twice.
func (s *MemoryStore) FinalizeConsumerCharge(in ConsumerChargeSettlement) (ConsumerChargeResult, error) {
	if err := validateConsumerSettlement(in); err != nil {
		return ConsumerChargeResult{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if old, ok := s.consumerSettlements[in.JobID]; ok {
		return replayConsumerSettlement(in, old)
	}
	collected, uncollected := settlementCost(in, s.balances[in.AccountID])
	referrer := ""
	if in.ReferralEnabled {
		if ref := s.referrersByCode[s.referrals[in.AccountID]]; ref != nil && ref.AccountID != in.AccountID {
			referrer = ref.AccountID
		}
	}
	reward := int64(0)
	if referrer != "" {
		reward = collected / (100 / ConsumerReferralPercent)
	}
	delta := collected - in.ReservedMicroUSD
	if (delta < 0 && s.balances[in.AccountID] > math.MaxInt64+delta) ||
		(reward > 0 && (s.balances[referrer] > math.MaxInt64-reward || s.withdrawable[referrer] > math.MaxInt64-reward)) {
		return ConsumerChargeResult{}, errors.New("store: consumer settlement balance overflow")
	}
	now := time.Now()
	if delta < 0 {
		s.creditLocked(in.AccountID, -delta, LedgerRefund, in.JobID, now)
	} else if delta > 0 {
		s.balances[in.AccountID] -= delta
		if s.withdrawable[in.AccountID] > s.balances[in.AccountID] {
			s.withdrawable[in.AccountID] = s.balances[in.AccountID]
		}
		reference := in.JobID
		if in.ReservedMicroUSD > 0 {
			reference = "overage:" + in.JobID
		}
		s.ledgerSeq++
		s.ledgerEntries = append(s.ledgerEntries, LedgerEntry{ID: s.ledgerSeq, AccountID: in.AccountID,
			Type: LedgerCharge, AmountMicroUSD: -delta, BalanceAfter: s.balances[in.AccountID], Reference: reference, CreatedAt: now})
	}
	if reward > 0 {
		s.creditLocked(referrer, reward, LedgerReferralReward, in.JobID, now)
		s.withdrawable[referrer] += reward
	}
	result := ConsumerChargeResult{CollectedMicroUSD: collected, ReferralRewardMicroUSD: reward, Applied: true, Uncollected: uncollected}
	s.consumerSettlements[in.JobID] = consumerSettlementRecord{Input: in, Result: result, Referrer: referrer}
	return result, nil
}
