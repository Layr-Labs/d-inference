package store

import (
	"errors"
	"math"
	"sort"
	"time"
)

func (s *MemoryStore) PutModelTokenPromotion(p ModelTokenPromotion) error {
	if err := p.Validate(); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.modelTokenPromotions == nil {
		s.modelTokenPromotions = make(map[string]ModelTokenPromotion)
	}
	if old, ok := s.modelTokenPromotions[p.ModelID]; ok && !old.sameTerms(p) {
		return ErrPromotionConflict
	}
	p.ClaimedCount = s.modelTokenPromotions[p.ModelID].ClaimedCount
	s.modelTokenPromotions[p.ModelID] = p.clone()
	return nil
}

func (s *MemoryStore) ListModelTokenPromotions() ([]ModelTokenPromotion, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]ModelTokenPromotion, 0, len(s.modelTokenPromotions))
	for _, p := range s.modelTokenPromotions {
		out = append(out, p.clone())
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ModelID < out[j].ModelID })
	return out, nil
}

func (s *MemoryStore) ClaimModelTokenPromotion(account, model string, now time.Time) ([]ModelTokenGrant, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	u := s.usersByAccountID[account]
	if u == nil || u.PrivyUserID == "" || u.Role == RoleService {
		return nil, ErrPromotionIneligible
	}
	if _, exists := s.modelTokenGrants[account][model]; exists {
		return s.modelTokenGrantsLocked(account), nil
	}
	p, exists := s.modelTokenPromotions[model]
	if !exists {
		return nil, ErrNotFound
	}
	if err := p.claimError(u, now); err != nil {
		return nil, err
	}
	if s.modelTokenGrants == nil {
		s.modelTokenGrants = make(map[string]map[string]ModelTokenGrant)
	}
	if s.modelTokenGrants[account] == nil {
		s.modelTokenGrants[account] = make(map[string]ModelTokenGrant)
	}
	s.modelTokenGrants[account][model] = ModelTokenGrant{ModelID: model, TotalTokens: p.Tokens, ClaimedAt: now}
	p.ClaimedCount++
	s.modelTokenPromotions[model] = p
	return s.modelTokenGrantsLocked(account), nil
}

func (s *MemoryStore) modelTokenGrantsLocked(account string) []ModelTokenGrant {
	out := make([]ModelTokenGrant, 0, len(s.modelTokenGrants[account]))
	for _, g := range s.modelTokenGrants[account] {
		g.RemainingTokens = g.TotalTokens - g.UsedTokens - g.ReservedTokens
		out = append(out, g)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ModelID < out[j].ModelID })
	return out
}

func (s *MemoryStore) ListModelTokenGrants(account string) ([]ModelTokenGrant, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.modelTokenGrantsLocked(account), nil
}

func (s *MemoryStore) ReserveModelTokens(id, account, model string, tokens int64, quote ModelTokenQuote) (*ModelTokenReservation, error) {
	if id == "" || account == "" || tokens < 0 {
		return nil, errors.New("invalid promotion reservation")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if r, ok := s.modelTokenReservations[id]; ok {
		if r.AccountID != account || r.ModelID != model {
			return nil, ErrPromotionConflict
		}
		return &r, nil
	}
	g, ok := s.modelTokenGrants[account][model]
	if !ok {
		return nil, nil
	}
	free := min(tokens, g.TotalTokens-g.UsedTokens-g.ReservedTokens)
	gross, paid, err := promotionQuote(quote, free)
	if err != nil {
		return nil, err
	}
	withdrawable := min(paid, max(paid-(s.balances[account]-s.withdrawable[account]), 0))
	if paid > 0 {
		if err := s.debitLocked(account, paid, LedgerCharge, "promotion-reserve:"+id); err != nil {
			return nil, err
		}
	}
	r := ModelTokenReservation{ID: id, AccountID: account, ModelID: model, FreeTokens: free, ReservedMicroUSD: paid, ReservedWithdrawableMicroUSD: withdrawable, GrossReservedMicroUSD: gross, State: "reserved", CreatedAt: time.Now(), TouchedAt: time.Now()}
	g.ReservedTokens += free
	s.modelTokenGrants[account][model] = g
	if s.modelTokenReservations == nil {
		s.modelTokenReservations = make(map[string]ModelTokenReservation)
	}
	s.modelTokenReservations[id] = r
	return &r, nil
}

func (s *MemoryStore) TopUpModelTokenReservation(id string, tokens int64, quote ModelTokenQuote) (*ModelTokenReservation, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	r, ok := s.modelTokenReservations[id]
	if !ok {
		return nil, ErrNotFound
	}
	if r.State != "reserved" {
		return nil, ErrPromotionReservationClosed
	}
	if tokens < 0 {
		return nil, errors.New("negative token reservation")
	}
	grant := s.modelTokenGrants[r.AccountID][r.ModelID]
	oldFree := r.FreeTokens
	if tokens > 0 {
		r.FreeTokens = max(oldFree, min(tokens, oldFree+grant.TotalTokens-grant.UsedTokens-grant.ReservedTokens))
	}
	gross, paid, err := promotionQuote(quote, r.FreeTokens)
	if err != nil {
		return nil, err
	}
	if delta := paid - r.ReservedMicroUSD; delta > 0 {
		r.ReservedWithdrawableMicroUSD += min(delta, max(delta-(s.balances[r.AccountID]-s.withdrawable[r.AccountID]), 0))
		if err := s.debitLocked(r.AccountID, delta, LedgerCharge, "promotion-topup:"+id); err != nil {
			return nil, err
		}
	}
	r.ReservedMicroUSD = max(r.ReservedMicroUSD, paid)
	r.GrossReservedMicroUSD = max(r.GrossReservedMicroUSD, gross)
	grant.ReservedTokens += r.FreeTokens - oldFree
	s.modelTokenGrants[r.AccountID][r.ModelID] = grant
	s.modelTokenReservations[id] = r
	return &r, nil
}

func (s *MemoryStore) ReleaseModelTokenReservation(id string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.releaseModelTokenLocked(id, time.Time{})
}

func (s *MemoryStore) releaseModelTokenLocked(id string, before time.Time) (bool, error) {

	r, ok := s.modelTokenReservations[id]
	if !ok || r.State != "reserved" || (!before.IsZero() && !r.TouchedAt.Before(before)) {
		return false, nil
	}
	if r.ReservedMicroUSD > math.MaxInt64-s.balances[r.AccountID] {
		return false, errors.New("refund balance overflow")
	}
	g := s.modelTokenGrants[r.AccountID][r.ModelID]
	g.ReservedTokens -= r.FreeTokens
	s.modelTokenGrants[r.AccountID][r.ModelID] = g
	if r.ReservedMicroUSD > 0 {
		s.creditLocked(r.AccountID, r.ReservedMicroUSD, LedgerRefund, "promotion-release:"+id, time.Now())
		s.withdrawable[r.AccountID] += r.ReservedWithdrawableMicroUSD
	}
	r.State = "released"
	s.modelTokenReservations[id] = r
	return true, nil
}

func (s *MemoryStore) SettleModelTokenReservation(id string, actual int64, quote ModelTokenQuote, earning *ModelTokenEarning) (ModelTokenSettlement, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	r, ok := s.modelTokenReservations[id]
	if !ok {
		return ModelTokenSettlement{}, ErrNotFound
	}
	if r.State != "reserved" {
		return ModelTokenSettlement{Reservation: r}, nil
	}
	next, err := promotionSettlement(r, actual, quote, earning)
	if err != nil {
		return ModelTokenSettlement{}, err
	}
	delta := next.ConsumerCostMicroUSD - r.ReservedMicroUSD
	if delta > s.balances[r.AccountID] {
		return ModelTokenSettlement{}, ErrInsufficientBalance
	}
	if delta < 0 && -delta > math.MaxInt64-s.balances[r.AccountID] {
		return ModelTokenSettlement{}, errors.New("refund balance overflow")
	}
	var carry int64
	if earning != nil {
		carry = s.modelTokenProviderCarries[earning.AccountID]
	}
	credited, remainder, err := carryModelTokenEarning(earning, carry)
	if err != nil {
		return ModelTokenSettlement{}, err
	}
	if earning != nil {
		balance := s.balances[earning.AccountID]
		if earning.AccountID == r.AccountID {
			balance -= delta
		}
		if credited.AmountMicroUSD > math.MaxInt64-balance {
			return ModelTokenSettlement{}, errors.New("provider balance overflow")
		}
	}
	if delta > 0 {
		_ = s.debitLocked(r.AccountID, delta, LedgerCharge, "promotion-settle:"+id)
	}
	if delta < 0 {
		s.creditLocked(r.AccountID, -delta, LedgerRefund, "promotion-settle:"+id, time.Now())
		s.withdrawable[r.AccountID] += min(-delta, r.ReservedWithdrawableMicroUSD)
	}
	g := s.modelTokenGrants[r.AccountID][r.ModelID]
	g.ReservedTokens -= r.FreeTokens
	g.UsedTokens += next.UsedTokens
	s.modelTokenGrants[r.AccountID][r.ModelID] = g
	if credited != nil {
		if s.modelTokenProviderCarries == nil {
			s.modelTokenProviderCarries = make(map[string]int64)
		}
		s.modelTokenProviderCarries[credited.AccountID] = remainder
		next.ProviderPayoutMicroUSD = credited.AmountMicroUSD
		if credited.AmountMicroUSD > 0 {
			_ = s.creditProviderAccountLocked(credited)
		}
	}
	s.modelTokenReservations[id] = next
	return ModelTokenSettlement{Reservation: next, Applied: true}, nil
}
