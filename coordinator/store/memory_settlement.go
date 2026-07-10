package store

import "time"

func (s *MemoryStore) SettleInference(settlement *InferenceSettlement) (bool, error) {
	if err := validateInferenceSettlement(settlement); err != nil {
		return false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if existing := s.inferenceSettlements[settlement.ReservationID]; existing != nil {
		if !equivalentInferenceSettlement(existing, settlement) {
			return false, ErrFinancialOperationConflict
		}
		return false, nil
	}
	finalizationKey := "finalize:" + settlement.ReservationID
	if _, finalized := s.balanceReservationOperations[finalizationKey]; finalized {
		return false, nil
	}
	if settlement.ProviderEarning != nil {
		for i := range s.providerEarnings {
			if s.providerEarnings[i].JobID == settlement.RequestID {
				return false, ErrFinancialOperationConflict
			}
		}
	}
	if settlement.Usage != nil {
		for i := range s.usage {
			if s.usage[i].RequestID == settlement.RequestID {
				return false, ErrFinancialOperationConflict
			}
		}
	}
	refund, refundWithdrawable := int64(0), int64(0)
	if settlement.ReservationPreDebited {
		refund = settlement.ReservedMicroUSD - settlement.CostMicroUSD
		refundWithdrawable = min(refund, settlement.ReservedWithdrawableMicroUSD)
	}
	now := time.Now()
	if !settlement.ReservationPreDebited && settlement.CostMicroUSD > 0 {
		if s.balances[settlement.ConsumerAccountID] < settlement.CostMicroUSD {
			return false, ErrInsufficientBalance
		}
		s.balances[settlement.ConsumerAccountID] -= settlement.CostMicroUSD
		if s.withdrawable[settlement.ConsumerAccountID] > s.balances[settlement.ConsumerAccountID] {
			s.withdrawable[settlement.ConsumerAccountID] = s.balances[settlement.ConsumerAccountID]
		}
		s.ledgerSeq++
		s.ledgerEntries = append(s.ledgerEntries, LedgerEntry{
			ID: s.ledgerSeq, AccountID: settlement.ConsumerAccountID,
			Type: LedgerCharge, AmountMicroUSD: -settlement.CostMicroUSD,
			BalanceAfter: s.balances[settlement.ConsumerAccountID],
			Reference:    settlement.RequestID, CreatedAt: now,
		})
	}
	if refund > 0 {
		s.creditLocked(
			settlement.ConsumerAccountID,
			refund,
			LedgerRefund,
			settlement.RequestID,
			now,
		)
		s.withdrawable[settlement.ConsumerAccountID] += refundWithdrawable
	}
	s.balanceReservationOperations[finalizationKey] = balanceReservationOperation{
		accountID: settlement.ConsumerAccountID, kind: "release",
		amountMicroUSD: refund, withdrawableMicroUSD: refundWithdrawable,
	}
	if earning := settlement.ProviderEarning; earning != nil && earning.AmountMicroUSD > 0 {
		cp := *earning
		if cp.CreatedAt.IsZero() {
			cp.CreatedAt = now
		}
		s.creditLocked(cp.AccountID, cp.AmountMicroUSD, LedgerPayout, cp.JobID, cp.CreatedAt)
		s.withdrawable[cp.AccountID] += cp.AmountMicroUSD
		s.providerEarningsSeq++
		cp.ID = s.providerEarningsSeq
		s.providerEarnings = append(s.providerEarnings, cp)
	}
	if settlement.PlatformFeeMicroUSD > 0 {
		s.creditLocked(
			"platform",
			settlement.PlatformFeeMicroUSD,
			LedgerPlatformFee,
			settlement.RequestID,
			now,
		)
	}
	if settlement.ReferralRewardMicroUSD > 0 {
		s.creditLocked(
			settlement.ReferrerAccountID,
			settlement.ReferralRewardMicroUSD,
			LedgerReferralReward,
			settlement.RequestID,
			now,
		)
		s.withdrawable[settlement.ReferrerAccountID] += settlement.ReferralRewardMicroUSD
	}
	if usage := settlement.Usage; usage != nil {
		cp := *usage
		if cp.Timestamp.IsZero() {
			cp.Timestamp = now
		}
		if cp.RequestLocation != nil {
			location := *cp.RequestLocation
			cp.RequestLocation = &location
		}
		s.usage = append(s.usage, cp)
		if cp.KeyID != "" && cp.CostMicroUSD > 0 {
			s.addKeySpendLocked(cp.KeyID, cp.CostMicroUSD, cp.Timestamp)
		}
	}
	s.inferenceSettlements[settlement.ReservationID] = cloneInferenceSettlement(settlement)
	return true, nil
}

func cloneInferenceSettlement(settlement *InferenceSettlement) *InferenceSettlement {
	cp := *settlement
	if settlement.ProviderEarning != nil {
		earning := *settlement.ProviderEarning
		cp.ProviderEarning = &earning
	}
	if settlement.Usage != nil {
		usage := *settlement.Usage
		if usage.RequestLocation != nil {
			location := *usage.RequestLocation
			usage.RequestLocation = &location
		}
		cp.Usage = &usage
	}
	return &cp
}
