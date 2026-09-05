package store

import (
	"sort"
	"time"
)

var _ GlobalPayoutStore = (*MemoryStore)(nil)

func (s *MemoryStore) PrepareGlobalRecipient(r GlobalRecipient) (*GlobalRecipient, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.globalRecipients == nil {
		s.globalRecipients = make(map[string]GlobalRecipient)
	}
	if old, ok := s.globalRecipients[r.AccountID]; ok && old.Country == r.Country {
		return &old, nil
	}
	s.globalRecipients[r.AccountID] = r
	return &r, nil
}
func (s *MemoryStore) SaveGlobalRecipient(r GlobalRecipient) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.globalRecipients[r.AccountID].ID != r.ID {
		return ErrPayoutConflict
	}
	s.globalRecipients[r.AccountID] = r
	return nil
}
func (s *MemoryStore) GetGlobalRecipient(accountID string) (*GlobalRecipient, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	r, ok := s.globalRecipients[accountID]
	if !ok {
		return nil, ErrNotFound
	}
	return &r, nil
}
func (s *MemoryStore) RemoveGlobalRecipient(accountID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.globalRecipients, accountID)
	return nil
}
func (s *MemoryStore) CreateGlobalPayoutQuote(p GlobalPayout) error {
	if err := validateGlobalQuote(p); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.globalPayouts == nil {
		s.globalPayouts = make(map[string]GlobalPayout)
	}
	if _, ok := s.globalPayouts[p.ID]; ok {
		return ErrPayoutConflict
	}
	s.globalPayouts[p.ID] = cloneGlobalPayout(p)
	return nil
}
func (s *MemoryStore) GetGlobalPayout(id string) (*GlobalPayout, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	p, ok := s.globalPayouts[id]
	if !ok {
		return nil, ErrNotFound
	}
	p = cloneGlobalPayout(p)
	return &p, nil
}
func (s *MemoryStore) GetGlobalPayoutByExternalID(id string) (*GlobalPayout, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	for _, p := range s.globalPayouts {
		if id != "" && p.ExternalID == id {
			p = cloneGlobalPayout(p)
			return &p, nil
		}
	}
	return nil, ErrNotFound
}
func (s *MemoryStore) BeginGlobalPayout(accountID, id string, now time.Time) (*GlobalPayout, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	p, ok := s.globalPayouts[id]
	if !ok || p.AccountID != accountID {
		return nil, ErrNotFound
	}
	if p.Status != "quoted" {
		p = cloneGlobalPayout(p)
		return &p, nil
	} // repeat confirm: same withdrawal, no debit
	if !p.ExpiresAt.After(now) {
		return nil, ErrPayoutQuoteExpired
	}
	r := s.globalRecipients[accountID]
	if r.ID != p.RecipientGeneration || !r.Ready || r.RecipientID != p.RecipientID || r.PayoutMethodID != p.PayoutMethodID {
		return nil, ErrPayoutConflict
	}
	if s.balances[accountID] < p.AmountMicroUSD || s.withdrawable[accountID] < p.AmountMicroUSD {
		return nil, ErrInsufficientBalance
	}
	s.globalPayoutLedgerLocked(p, -p.AmountMicroUSD, LedgerStripePayout, "global_payout:"+id, now)
	p.Status = "pending"
	p.SubmittedAt = now
	s.globalPayouts[id] = p
	p = cloneGlobalPayout(p)
	return &p, nil
}
func (s *MemoryStore) globalPayoutLedgerLocked(p GlobalPayout, amount int64, kind LedgerEntryType, ref string, now time.Time) {
	s.balances[p.AccountID] += amount
	s.withdrawable[p.AccountID] += amount
	s.ledgerSeq++
	s.ledgerEntries = append(s.ledgerEntries, LedgerEntry{ID: s.ledgerSeq, AccountID: p.AccountID, Type: kind, AmountMicroUSD: amount, BalanceAfter: s.balances[p.AccountID], Reference: ref, CreatedAt: now})
}
func (s *MemoryStore) ClaimGlobalPayout(id string, now time.Time) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	p, ok := s.globalPayouts[id]
	if !ok {
		return false, ErrNotFound
	}
	if p.Status == "quoted" || p.Refunded || p.LeaseUntil.After(now) {
		return false, nil
	}
	if p.ExternalID == "" {
		p.DispatchAttempts++
	}
	p.LeaseUntil = now.Add(time.Minute)
	s.globalPayouts[id] = p
	return true, nil
}
func (s *MemoryStore) ApplyGlobalPayout(id string, r GlobalPayoutResult, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	p, ok := s.globalPayouts[id]
	if !ok {
		return ErrNotFound
	}
	refund, err := applyGlobalResult(&p, r, now)
	if err != nil {
		return err
	}
	if refund {
		s.globalPayoutLedgerLocked(p, p.AmountMicroUSD, LedgerRefund, "global_payout_refund:"+id, now)
	}
	s.globalPayouts[id] = p
	return nil
}
func (s *MemoryStore) ListGlobalPayouts(accountID string, limit int) ([]GlobalPayout, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := []GlobalPayout{}
	for _, p := range s.globalPayouts {
		if p.AccountID == accountID && p.Status != "quoted" {
			out = append(out, cloneGlobalPayout(p))
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].SubmittedAt.After(out[j].SubmittedAt) })
	return limitGlobalPayouts(out, limit), nil
}
func (s *MemoryStore) ListGlobalPayoutsToReconcile(now time.Time, limit int) ([]GlobalPayout, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := []GlobalPayout{}
	for _, p := range s.globalPayouts {
		if globalPayoutReconcile(p, now) {
			out = append(out, cloneGlobalPayout(p))
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CheckedAt.Before(out[j].CheckedAt) })
	return limitGlobalPayouts(out, limit), nil
}
func limitGlobalPayouts(p []GlobalPayout, limit int) []GlobalPayout {
	if limit < 1 || limit > 200 {
		limit = 200
	}
	if len(p) > limit {
		return p[:limit]
	}
	return p
}
