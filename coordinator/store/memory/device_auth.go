package memory

import (
	"errors"
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *MemoryStore) CreateDeviceCode(dc *store.DeviceCode) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if _, exists := s.history.DeviceCodesByUserCode[dc.UserCode]; exists {
		return fmt.Errorf("user code %q already exists", dc.UserCode)
	}
	copy := *dc
	s.history.DeviceCodesByCode[dc.DeviceCode] = &copy
	s.history.DeviceCodesByUserCode[dc.UserCode] = &copy
	return nil
}

func (s *MemoryStore) GetDeviceCode(deviceCode string) (*store.DeviceCode, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	dc, ok := s.history.DeviceCodesByCode[deviceCode]
	if !ok {
		return nil, errors.New("device code not found")
	}
	copy := *dc
	return &copy, nil
}

func (s *MemoryStore) GetDeviceCodeByUserCode(userCode string) (*store.DeviceCode, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	dc, ok := s.history.DeviceCodesByUserCode[userCode]
	if !ok {
		return nil, fmt.Errorf("user code %q not found", userCode)
	}
	copy := *dc
	return &copy, nil
}

func (s *MemoryStore) ApproveDeviceCode(deviceCode, accountID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	dc, ok := s.history.DeviceCodesByCode[deviceCode]
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
	for code, dc := range s.history.DeviceCodesByCode {
		if now.After(dc.ExpiresAt) {
			delete(s.history.DeviceCodesByCode, code)
			delete(s.history.DeviceCodesByUserCode, dc.UserCode)
		}
	}
	return nil
}

func (s *MemoryStore) CreateProviderToken(pt *store.ProviderToken) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if _, exists := s.providerTokens[pt.TokenHash]; exists {
		return errors.New("provider token already exists")
	}
	copy := *pt
	s.providerTokens[pt.TokenHash] = &copy
	return nil
}

func (s *MemoryStore) GetProviderToken(token string) (*store.ProviderToken, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	h := store.HashKey(token)
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

	h := store.HashKey(token)
	pt, ok := s.providerTokens[h]
	if !ok {
		return errors.New("provider token not found")
	}
	pt.Active = false
	return nil
}
