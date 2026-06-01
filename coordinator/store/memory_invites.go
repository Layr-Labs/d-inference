package store

import (
	"fmt"
	"time"
)

// --- Invite Codes ---

func (s *MemoryStore) CreateInviteCode(code *InviteCode) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if _, exists := s.inviteCodes[code.Code]; exists {
		return fmt.Errorf("invite code %q already exists", code.Code)
	}
	cp := *code
	s.inviteCodes[code.Code] = &cp
	return nil
}

func (s *MemoryStore) GetInviteCode(code string) (*InviteCode, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	ic, ok := s.inviteCodes[code]
	if !ok {
		return nil, fmt.Errorf("invite code %q not found", code)
	}
	cp := *ic
	return &cp, nil
}

func (s *MemoryStore) ListInviteCodes() []InviteCode {
	s.mu.RLock()
	defer s.mu.RUnlock()

	codes := make([]InviteCode, 0, len(s.inviteCodes))
	for _, ic := range s.inviteCodes {
		codes = append(codes, *ic)
	}
	return codes
}

func (s *MemoryStore) DeactivateInviteCode(code string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	ic, ok := s.inviteCodes[code]
	if !ok {
		return fmt.Errorf("invite code %q not found", code)
	}
	ic.Active = false
	return nil
}

func (s *MemoryStore) RedeemInviteCode(code string, accountID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	ic, ok := s.inviteCodes[code]
	if !ok {
		return fmt.Errorf("invite code %q not found", code)
	}
	if !ic.Active {
		return fmt.Errorf("invite code %q is inactive", code)
	}
	if ic.ExpiresAt != nil && time.Now().After(*ic.ExpiresAt) {
		return fmt.Errorf("invite code %q has expired", code)
	}
	if ic.MaxUses > 0 && ic.UsedCount >= ic.MaxUses {
		return fmt.Errorf("invite code %q has reached max uses", code)
	}
	if acctCodes, ok := s.accountRedemptions[accountID]; ok && acctCodes[code] {
		return fmt.Errorf("account has already redeemed code %q", code)
	}

	ic.UsedCount++
	s.inviteRedemptions[code] = append(s.inviteRedemptions[code], InviteRedemption{
		Code:      code,
		AccountID: accountID,
		CreatedAt: time.Now(),
	})
	if s.accountRedemptions[accountID] == nil {
		s.accountRedemptions[accountID] = make(map[string]bool)
	}
	s.accountRedemptions[accountID][code] = true
	return nil
}

func (s *MemoryStore) HasRedeemedInviteCode(code, accountID string) bool {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if acctCodes, ok := s.accountRedemptions[accountID]; ok {
		return acctCodes[code]
	}
	return false
}
