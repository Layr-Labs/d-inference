package store

import (
	"strings"
	"time"
)

func (s *MemoryStore) SettleInference(settlement *InferenceSettlement) (InferenceSettlementDisposition, error) {
	if err := validateInferenceSettlement(settlement); err != nil {
		return "", err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if existing := s.inferenceSettlements[settlement.ReservationID]; existing != nil {
		if !equivalentInferenceSettlement(existing, settlement) {
			return "", ErrFinancialOperationConflict
		}
		return InferenceSettlementReplayed, nil
	}
	if review := s.inferenceSettlementReviews[settlement.ReservationID]; review != nil {
		if review.RequestID != settlement.RequestID {
			return "", ErrFinancialOperationConflict
		}
		return InferenceSettlementReviewPending, nil
	}
	if settlement.ReservationPreDebited {
		total, withdrawable, found := int64(0), int64(0), false
		for operationKey, operation := range s.balanceReservationOperations {
			isBase := operationKey == settlement.ReservationID
			isTopUp := strings.HasPrefix(operationKey, "topup:"+settlement.ReservationID+":")
			if operation.kind != "reserve" || (!isBase && !isTopUp) {
				continue
			}
			if isTopUp {
				releaseKey := "topup-release:" + strings.TrimPrefix(operationKey, "topup:")
				if _, released := s.balanceReservationOperations[releaseKey]; released {
					continue
				}
			}
			if operation.accountID != settlement.ConsumerAccountID {
				return "", ErrFinancialOperationConflict
			}
			found = true
			total += operation.amountMicroUSD
			withdrawable += operation.withdrawableMicroUSD
		}
		if !found || total != settlement.ReservedMicroUSD ||
			withdrawable != settlement.ReservedWithdrawableMicroUSD {
			return "", ErrFinancialOperationConflict
		}
	}
	finalizationKey := "finalize:" + settlement.ReservationID
	if _, finalized := s.balanceReservationOperations[finalizationKey]; finalized {
		return InferenceSettlementAlreadyReleased, nil
	}
	if settlement.ProviderEarning != nil {
		for i := range s.providerEarnings {
			if s.providerEarnings[i].JobID == settlement.RequestID {
				return "", ErrFinancialOperationConflict
			}
		}
	}
	if settlement.Usage != nil {
		for i := range s.usage {
			if s.usage[i].RequestID == settlement.RequestID {
				return "", ErrFinancialOperationConflict
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
			return "", ErrInsufficientBalance
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
	return InferenceSettlementApplied, nil
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

func (s *MemoryStore) RecordInferenceSettlementReview(
	settlement *InferenceSettlement,
	reason string,
) (InferenceSettlementDisposition, error) {
	if settlement == nil || settlement.ReservationID == "" ||
		settlement.RequestID == "" || reason == "" {
		return "", ErrFinancialOperationConflict
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if existing := s.inferenceSettlements[settlement.ReservationID]; existing != nil {
		if !equivalentInferenceSettlement(existing, settlement) {
			return "", ErrFinancialOperationConflict
		}
		return InferenceSettlementReplayed, nil
	}
	if _, released := s.balanceReservationOperations["finalize:"+settlement.ReservationID]; released {
		return InferenceSettlementAlreadyReleased, nil
	}
	if existing := s.inferenceSettlementReviews[settlement.ReservationID]; existing != nil {
		if existing.RequestID != settlement.RequestID {
			return "", ErrFinancialOperationConflict
		}
		return InferenceSettlementReviewPending, nil
	}
	s.inferenceSettlementReviews[settlement.ReservationID] = cloneInferenceSettlement(settlement)
	s.inferenceSettlementReasons[settlement.ReservationID] = reason
	return InferenceSettlementReviewPending, nil
}

func (s *MemoryStore) RecoverStaleInferenceReservations(_ time.Time) (int, error) {
	// The memory store has no restart persistence, so it cannot contain holds
	// orphaned by a previous process.
	return 0, nil
}
