package memory

import (
	"encoding/json"
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/store/shared"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

func cloneGlobalPayout(p store.GlobalPayout) store.GlobalPayout {
	p.Request = append(json.RawMessage(nil), p.Request...)
	p.EstimatedStripeFees = append(json.RawMessage(nil), p.EstimatedStripeFees...)
	if p.Rejection != nil {
		r := *p.Rejection
		p.Rejection = &r
	}
	return p
}

func globalPayoutReconcile(p store.GlobalPayout, now time.Time) bool {
	return !p.RequiresManualReconciliation() && (p.Status == "pending" || p.Status == "processing" || (p.Status == "posted" && now.Sub(p.SubmittedAt) < 90*24*time.Hour)) && !p.LeaseUntil.After(now) && now.Sub(p.CheckedAt) >= time.Minute
}

var _ store.GlobalPayoutStore = (*MemoryStore)(nil)

func (s *MemoryStore) PrepareGlobalRecipient(r store.GlobalRecipient) (*store.GlobalRecipient, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.globalRecipients == nil {
		s.globalRecipients = make(map[string]store.GlobalRecipient)
	}
	if old, ok := s.globalRecipients[r.AccountID]; ok && old.Country == r.Country {
		return &old, nil
	}
	s.globalRecipients[r.AccountID] = r
	return &r, nil
}

func (s *MemoryStore) SaveGlobalRecipient(r store.GlobalRecipient) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.globalRecipients[r.AccountID].ID != r.ID {
		return store.ErrPayoutConflict
	}
	s.globalRecipients[r.AccountID] = r
	return nil
}

func (s *MemoryStore) GetGlobalRecipient(accountID string) (*store.GlobalRecipient, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	r, ok := s.globalRecipients[accountID]
	if !ok {
		return nil, store.ErrNotFound
	}
	return &r, nil
}

func (s *MemoryStore) RemoveGlobalRecipient(accountID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, exists := s.globalRecipients[accountID]; exists {
		s.globalRecipients[accountID] = store.GlobalRecipient{ID: uuid.NewString(), AccountID: accountID}
	}
	return nil
}

func (s *MemoryStore) CreateGlobalPayoutQuote(p store.GlobalPayout) error {
	if err := shared.ValidateGlobalQuote(p); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.globalPayouts == nil {
		s.globalPayouts = make(map[string]store.GlobalPayout)
	}
	if _, ok := s.globalPayouts[p.ID]; ok {
		return store.ErrPayoutConflict
	}
	s.globalPayouts[p.ID] = cloneGlobalPayout(p)
	return nil
}

func (s *MemoryStore) GetGlobalPayout(id string) (*store.GlobalPayout, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	p, ok := s.globalPayouts[id]
	if !ok {
		return nil, store.ErrNotFound
	}
	p = cloneGlobalPayout(p)
	return &p, nil
}

func (s *MemoryStore) GetGlobalPayoutByExternalID(id string) (*store.GlobalPayout, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	for _, p := range s.globalPayouts {
		if id != "" && p.ExternalID == id {
			p = cloneGlobalPayout(p)
			return &p, nil
		}
	}
	return nil, store.ErrNotFound
}

func (s *MemoryStore) BeginGlobalPayout(accountID, id string, now time.Time) (*store.GlobalPayout, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	p, ok := s.globalPayouts[id]
	if !ok || p.AccountID != accountID {
		return nil, store.ErrNotFound
	}
	if p.Status != "quoted" {
		p = cloneGlobalPayout(p)
		return &p, nil
	} // repeat confirm: same withdrawal, no debit
	if p.QuoteInvalidated || !p.ExpiresAt.After(now) {
		return nil, store.ErrPayoutQuoteExpired
	}
	r := s.globalRecipients[accountID]
	if r.ID != p.RecipientGeneration || !r.Ready || r.RecipientID != p.RecipientID || r.PayoutMethodID != p.PayoutMethodID {
		return nil, store.ErrPayoutConflict
	}
	if s.balances[accountID] < p.AmountMicroUSD || s.withdrawable[accountID] < p.AmountMicroUSD {
		return nil, store.ErrInsufficientBalance
	}
	s.globalPayoutLedgerLocked(p, -p.AmountMicroUSD, store.LedgerStripePayout, "global_payout:"+id, now)
	p.Status = "pending"
	p.SubmittedAt = now
	s.globalPayouts[id] = p
	p = cloneGlobalPayout(p)
	return &p, nil
}

func (s *MemoryStore) globalPayoutLedgerLocked(p store.GlobalPayout, amount int64, kind store.LedgerEntryType, ref string, now time.Time) {
	if s.refuseErasedCreditLocked(p.AccountID, amount, kind, ref, now) {
		return
	}
	s.balances[p.AccountID] += amount
	s.withdrawable[p.AccountID] += amount
	s.ledgerSeq++
	s.history.LedgerEntries = append(s.history.LedgerEntries, store.LedgerEntry{ID: s.ledgerSeq, AccountID: p.AccountID, Type: kind, AmountMicroUSD: amount, BalanceAfter: s.balances[p.AccountID], Reference: ref, CreatedAt: now})
}

func (s *MemoryStore) ClaimGlobalPayout(id string, now time.Time) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	p, ok := s.globalPayouts[id]
	if !ok {
		return false, store.ErrNotFound
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

func (s *MemoryStore) ApplyGlobalPayout(id string, r store.GlobalPayoutResult, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	p, ok := s.globalPayouts[id]
	if !ok {
		return store.ErrNotFound
	}
	refund, err := shared.ApplyGlobalResult(&p, r, now)
	if err != nil {
		return err
	}
	if refund {
		s.globalPayoutLedgerLocked(p, p.AmountMicroUSD, store.LedgerRefund, "global_payout_refund:"+id, now)
	}
	s.globalPayouts[id] = p
	return nil
}

func (s *MemoryStore) ListGlobalPayouts(accountID string, limit int) ([]store.GlobalPayout, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := []store.GlobalPayout{}
	for _, p := range s.globalPayouts {
		if p.AccountID == accountID && p.Status != "quoted" {
			out = append(out, cloneGlobalPayout(p))
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].SubmittedAt.After(out[j].SubmittedAt) })
	return limitGlobalPayouts(out, limit), nil
}

func (s *MemoryStore) ListGlobalPayoutsToReconcile(now time.Time, limit int) ([]store.GlobalPayout, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := []store.GlobalPayout{}
	for _, p := range s.globalPayouts {
		if globalPayoutReconcile(p, now) {
			out = append(out, cloneGlobalPayout(p))
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CheckedAt.Before(out[j].CheckedAt) })
	return limitGlobalPayouts(out, limit), nil
}

func limitGlobalPayouts(p []store.GlobalPayout, limit int) []store.GlobalPayout {
	if limit < 1 || limit > 200 {
		limit = 200
	}
	if len(p) > limit {
		return p[:limit]
	}
	return p
}
