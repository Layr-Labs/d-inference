package memory

import (
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// CreateReferrer registers an account as a referrer with the given code.
func (s *MemoryStore) CreateReferrer(accountID, code string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.accountAdmissionLocked(accountID); err != nil {
		return err
	}

	if _, exists := s.referrersByCode[code]; exists {
		return fmt.Errorf("%w: referral code %q already exists", store.ErrReferralConflict, code)
	}
	if _, exists := s.referrersByAccount[accountID]; exists {
		return fmt.Errorf("%w: account %q is already a referrer", store.ErrReferralConflict, accountID)
	}

	ref := &store.Referrer{
		AccountID: accountID,
		Code:      code,
		CreatedAt: time.Now(),
	}
	s.referrersByCode[code] = ref
	s.referrersByAccount[accountID] = ref
	return nil
}

// GetReferrerByCode returns the referrer for a given referral code.
func (s *MemoryStore) GetReferrerByCode(code string) (*store.Referrer, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	ref, ok := s.referrersByCode[code]
	if !ok {
		return nil, fmt.Errorf("referral code %q: %w", code, store.ErrNotFound)
	}
	copy := *ref
	return &copy, nil
}

// GetReferrerByAccount returns the referrer record for an account.
func (s *MemoryStore) GetReferrerByAccount(accountID string) (*store.Referrer, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	ref, ok := s.referrersByAccount[accountID]
	if !ok {
		return nil, fmt.Errorf("%w: account %q is not a referrer", store.ErrNotFound, accountID)
	}
	copy := *ref
	return &copy, nil
}

// RecordReferral records that referredAccountID was referred by referrerCode.
func (s *MemoryStore) RecordReferral(referrerCode, referredAccountID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	ref, exists := s.referrersByCode[referrerCode]
	if !exists {
		return fmt.Errorf("%w: referral code %q", store.ErrNotFound, referrerCode)
	}
	if ref.AccountID == referredAccountID {
		return fmt.Errorf("%w: cannot refer yourself", store.ErrReferralConflict)
	}
	if existing, exists := s.referrals[referredAccountID]; exists {
		if existing == referrerCode {
			return nil
		}
		return fmt.Errorf("%w: account already has a referrer", store.ErrReferralConflict)
	}

	s.referrals[referredAccountID] = referrerCode
	s.referralCounts[referrerCode]++
	return nil
}

// GetReferrerForAccount returns the referrer code that referred this account.
func (s *MemoryStore) GetReferrerForAccount(accountID string) (string, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	code, ok := s.referrals[accountID]
	if !ok {
		return "", nil
	}
	return code, nil
}

// GetReferralStats returns referral statistics for a code.
func (s *MemoryStore) GetReferralStats(code string) (*store.ReferralStats, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	ref, ok := s.referrersByCode[code]
	if !ok {
		return nil, fmt.Errorf("%w: referral code %q", store.ErrNotFound, code)
	}

	// Sum referral rewards from ledger
	var totalRewards int64
	for _, entry := range s.history.LedgerEntries {
		if entry.AccountID == ref.AccountID && entry.Type == store.LedgerReferralReward {
			totalRewards += entry.AmountMicroUSD
		}
	}

	var totalSpend int64
	for _, settlement := range s.consumerSettlements {
		if settlement.Referrer == ref.AccountID {
			totalSpend += settlement.Result.CollectedMicroUSD
		}
	}
	return &store.ReferralStats{
		Code:                       code,
		TotalReferred:              s.referralCounts[code],
		TotalRewardsMicroUSD:       totalRewards,
		TotalReferredSpendMicroUSD: totalSpend,
	}, nil
}
