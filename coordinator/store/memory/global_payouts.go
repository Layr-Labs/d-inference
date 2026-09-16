package memory

import (
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"github.com/eigeninference/d-inference/coordinator/store/internal/payoutstate"
)

var _ contracts.GlobalPayoutStore = (*Store)(nil)

func (s *Store) PrepareGlobalRecipient(r contracts.GlobalRecipient) (*contracts.GlobalRecipient, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.globalRecipients == nil {
		s.globalRecipients = make(map[string]contracts.GlobalRecipient)
	}
	if old, ok := s.globalRecipients[r.AccountID]; ok && old.Country == r.Country {
		return &old, nil
	}
	s.globalRecipients[r.AccountID] = r
	return &r, nil
}

func (s *Store) SaveGlobalRecipient(r contracts.GlobalRecipient) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.globalRecipients[r.AccountID].ID != r.ID {
		return contracts.ErrPayoutConflict
	}
	s.globalRecipients[r.AccountID] = r
	return nil
}

func (s *Store) GetGlobalRecipient(accountID string) (*contracts.GlobalRecipient, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	r, ok := s.globalRecipients[accountID]
	if !ok {
		return nil, contracts.ErrNotFound
	}
	return &r, nil
}

func (s *Store) RemoveGlobalRecipient(accountID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.globalRecipients, accountID)
	return nil
}

func (s *Store) CreateGlobalPayoutQuote(p contracts.GlobalPayout) error {
	if err := payoutstate.ValidateGlobalQuote(p); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.globalPayouts == nil {
		s.globalPayouts = make(map[string]contracts.GlobalPayout)
	}
	if _, ok := s.globalPayouts[p.ID]; ok {
		return contracts.ErrPayoutConflict
	}
	s.globalPayouts[p.ID] = payoutstate.CloneGlobalPayout(p)
	return nil
}

func (s *Store) GetGlobalPayout(id string) (*contracts.GlobalPayout, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	p, ok := s.globalPayouts[id]
	if !ok {
		return nil, contracts.ErrNotFound
	}
	p = payoutstate.CloneGlobalPayout(p)
	return &p, nil
}

func (s *Store) GetGlobalPayoutByExternalID(id string) (*contracts.GlobalPayout, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	for _, p := range s.globalPayouts {
		if id != "" && p.ExternalID == id {
			p = payoutstate.CloneGlobalPayout(p)
			return &p, nil
		}
	}
	return nil, contracts.ErrNotFound
}

func (s *Store) BeginGlobalPayout(accountID, id string, now time.Time) (*contracts.GlobalPayout, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	p, ok := s.globalPayouts[id]
	if !ok || p.AccountID != accountID {
		return nil, contracts.ErrNotFound
	}
	if p.Status != "quoted" {
		p = payoutstate.CloneGlobalPayout(p)
		return &p, nil
	} // repeat confirm: same withdrawal, no debit
	if p.QuoteInvalidated || !p.ExpiresAt.After(now) {
		return nil, contracts.ErrPayoutQuoteExpired
	}
	r := s.globalRecipients[accountID]
	if r.ID != p.RecipientGeneration || !r.Ready || r.RecipientID != p.RecipientID || r.PayoutMethodID != p.PayoutMethodID {
		return nil, contracts.ErrPayoutConflict
	}
	if s.balances[accountID] < p.AmountMicroUSD || s.withdrawable[accountID] < p.AmountMicroUSD {
		return nil, contracts.ErrInsufficientBalance
	}
	s.globalPayoutLedgerLocked(p, -p.AmountMicroUSD, contracts.LedgerStripePayout, "global_payout:"+id, now)
	p.Status = "pending"
	p.SubmittedAt = now
	s.globalPayouts[id] = p
	p = payoutstate.CloneGlobalPayout(p)
	return &p, nil
}

func (s *Store) globalPayoutLedgerLocked(p contracts.GlobalPayout, amount int64, kind contracts.LedgerEntryType, ref string, now time.Time) {
	s.balances[p.AccountID] += amount
	s.withdrawable[p.AccountID] += amount
	s.ledgerSeq++
	s.ledgerEntries = append(s.ledgerEntries, contracts.LedgerEntry{ID: s.ledgerSeq, AccountID: p.AccountID, Type: kind, AmountMicroUSD: amount, BalanceAfter: s.balances[p.AccountID], Reference: ref, CreatedAt: now})
}

func (s *Store) ClaimGlobalPayout(id string, now time.Time) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	p, ok := s.globalPayouts[id]
	if !ok {
		return false, contracts.ErrNotFound
	}
	if p.Status == "quoted" || p.Refunded || p.RequiresManualReconciliation() || p.LeaseUntil.After(now) {
		return false, nil
	}
	if p.ExternalID == "" && p.Rejection == nil {
		p.DispatchAttempts++
	}
	p.LeaseUntil = now.Add(time.Minute)
	s.globalPayouts[id] = p
	return true, nil
}

func (s *Store) ApplyGlobalPayout(id string, r contracts.GlobalPayoutResult, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	p, ok := s.globalPayouts[id]
	if !ok {
		return contracts.ErrNotFound
	}
	refund, err := payoutstate.ApplyGlobalResult(&p, r, now)
	if err != nil {
		return err
	}
	if refund {
		s.globalPayoutLedgerLocked(p, p.AmountMicroUSD, contracts.LedgerRefund, "global_payout_refund:"+id, now)
	}
	s.globalPayouts[id] = p
	return nil
}

func (s *Store) ListGlobalPayouts(accountID string, limit int) ([]contracts.GlobalPayout, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := []contracts.GlobalPayout{}
	for _, p := range s.globalPayouts {
		if p.AccountID == accountID && p.Status != "quoted" {
			out = append(out, payoutstate.CloneGlobalPayout(p))
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].SubmittedAt.After(out[j].SubmittedAt) })
	return limitGlobalPayouts(out, limit), nil
}

func (s *Store) ListGlobalPayoutsToReconcile(now time.Time, limit int) ([]contracts.GlobalPayout, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := []contracts.GlobalPayout{}
	for _, p := range s.globalPayouts {
		if payoutstate.GlobalPayoutReconcile(p, now) {
			out = append(out, payoutstate.CloneGlobalPayout(p))
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CheckedAt.Before(out[j].CheckedAt) })
	return limitGlobalPayouts(out, limit), nil
}

func limitGlobalPayouts(p []contracts.GlobalPayout, limit int) []contracts.GlobalPayout {
	if limit < 1 || limit > 200 {
		limit = 200
	}
	if len(p) > limit {
		return p[:limit]
	}
	return p
}
