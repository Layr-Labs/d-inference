package store

import (
	"errors"
	"fmt"
	"time"
)

// --- Device Authorization ---

func (s *MemoryStore) CreateDeviceCode(dc *DeviceCode) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if _, exists := s.deviceCodesByUserCode[dc.UserCode]; exists {
		return fmt.Errorf("user code %q already exists", dc.UserCode)
	}
	copy := *dc
	s.deviceCodesByCode[dc.DeviceCode] = &copy
	s.deviceCodesByUserCode[dc.UserCode] = &copy
	return nil
}

func (s *MemoryStore) GetDeviceCode(deviceCode string) (*DeviceCode, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	dc, ok := s.deviceCodesByCode[deviceCode]
	if !ok {
		return nil, errors.New("device code not found")
	}
	copy := *dc
	return &copy, nil
}

func (s *MemoryStore) GetDeviceCodeByUserCode(userCode string) (*DeviceCode, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	dc, ok := s.deviceCodesByUserCode[userCode]
	if !ok {
		return nil, fmt.Errorf("user code %q not found", userCode)
	}
	copy := *dc
	return &copy, nil
}

func (s *MemoryStore) ApproveDeviceCode(deviceCode, accountID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	dc, ok := s.deviceCodesByCode[deviceCode]
	if !ok {
		return errors.New("device code not found")
	}
	if dc.Status != "pending" {
		return fmt.Errorf("device code is %s, not pending", dc.Status)
	}
	if time.Now().After(dc.ExpiresAt) {
		dc.Status = "expired"
		return errors.New("device code has expired")
	}
	dc.Status = "approved"
	dc.AccountID = accountID
	return nil
}

func (s *MemoryStore) DeleteExpiredDeviceCodes() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now()
	for code, dc := range s.deviceCodesByCode {
		if now.After(dc.ExpiresAt) {
			delete(s.deviceCodesByCode, code)
			delete(s.deviceCodesByUserCode, dc.UserCode)
		}
	}
	return nil
}

// --- Provider Tokens ---

func (s *MemoryStore) CreateProviderToken(pt *ProviderToken) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if _, exists := s.providerTokens[pt.TokenHash]; exists {
		return errors.New("provider token already exists")
	}
	copy := *pt
	s.providerTokens[pt.TokenHash] = &copy
	return nil
}

func (s *MemoryStore) GetProviderToken(token string) (*ProviderToken, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	h := sha256Hex(token)
	pt, ok := s.providerTokens[h]
	if !ok {
		return nil, errors.New("provider token not found")
	}
	if !pt.Active {
		return nil, errors.New("provider token is revoked")
	}
	copy := *pt
	return &copy, nil
}

func (s *MemoryStore) RevokeProviderToken(token string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	h := sha256Hex(token)
	pt, ok := s.providerTokens[h]
	if !ok {
		return errors.New("provider token not found")
	}
	pt.Active = false
	return nil
}

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
