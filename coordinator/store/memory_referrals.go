package store

import (
	"errors"
	"fmt"
	"time"
)

// --- Referral System ---

// CreateReferrer registers an account as a referrer with the given code.
func (s *MemoryStore) CreateReferrer(accountID, code string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if _, exists := s.referrersByCode[code]; exists {
		return fmt.Errorf("referral code %q already exists", code)
	}
	if _, exists := s.referrersByAccount[accountID]; exists {
		return fmt.Errorf("account %q is already a referrer", accountID)
	}

	ref := &Referrer{
		AccountID: accountID,
		Code:      code,
		CreatedAt: time.Now(),
	}
	s.referrersByCode[code] = ref
	s.referrersByAccount[accountID] = ref
	return nil
}

// GetReferrerByCode returns the referrer for a given referral code.
func (s *MemoryStore) GetReferrerByCode(code string) (*Referrer, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	ref, ok := s.referrersByCode[code]
	if !ok {
		return nil, fmt.Errorf("referral code %q not found", code)
	}
	copy := *ref
	return &copy, nil
}

// GetReferrerByAccount returns the referrer record for an account.
func (s *MemoryStore) GetReferrerByAccount(accountID string) (*Referrer, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	ref, ok := s.referrersByAccount[accountID]
	if !ok {
		return nil, fmt.Errorf("account %q is not a referrer", accountID)
	}
	copy := *ref
	return &copy, nil
}

// RecordReferral records that referredAccountID was referred by referrerCode.
func (s *MemoryStore) RecordReferral(referrerCode, referredAccountID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if _, exists := s.referrersByCode[referrerCode]; !exists {
		return fmt.Errorf("referral code %q not found", referrerCode)
	}
	if _, exists := s.referrals[referredAccountID]; exists {
		return errors.New("account already has a referrer")
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
func (s *MemoryStore) GetReferralStats(code string) (*ReferralStats, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	ref, ok := s.referrersByCode[code]
	if !ok {
		return nil, fmt.Errorf("referral code %q not found", code)
	}

	// Sum referral rewards from ledger
	var totalRewards int64
	for _, entry := range s.ledgerEntries {
		if entry.AccountID == ref.AccountID && entry.Type == LedgerReferralReward {
			totalRewards += entry.AmountMicroUSD
		}
	}

	return &ReferralStats{
		Code:                 code,
		TotalReferred:        s.referralCounts[code],
		TotalRewardsMicroUSD: totalRewards,
	}, nil
}
