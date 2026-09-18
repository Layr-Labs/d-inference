package store

import (
	"context"
	"math"
	"time"
)

type trialAllowanceKey struct{ account, campaign string }

func (s *MemoryStore) ReserveTrial(ctx context.Context, r TrialReservation) (TrialReservation, error) {
	if err := ctx.Err(); err != nil {
		return TrialReservation{}, err
	}
	if err := validateTrialReservation(r); err != nil {
		return TrialReservation{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.trialReservations == nil {
		s.trialReservations = make(map[string]TrialReservation)
		s.trialAllowances = make(map[trialAllowanceKey]TrialAllowance)
		s.trialSettlements = make(map[string]TrialSettlement)
	}
	if old, ok := s.trialReservations[r.ID]; ok {
		if !sameTrialReservation(old, r) {
			return TrialReservation{}, ErrTrialConflict
		}
		return copyTrialReservation(old), nil
	}
	key := trialAllowanceKey{r.AccountID, r.CampaignID}
	a, ok := s.trialAllowances[key]
	if !ok {
		a = TrialAllowance{AccountID: r.AccountID, CampaignID: r.CampaignID, LimitTokens: r.LimitTokens}
	}
	if a.LimitTokens != r.LimitTokens {
		return TrialReservation{}, ErrTrialConflict
	}
	if err := trialAdmissionError(a, r.ReservedTokens); err != nil {
		if err == ErrTrialBusy {
			for _, held := range s.trialReservations {
				if held.AccountID == r.AccountID && held.CampaignID == r.CampaignID && held.State == TrialUnresolved {
					return TrialReservation{}, ErrTrialUnavailable
				}
			}
		}
		return TrialReservation{}, err
	}
	a.ReservedTokens += r.ReservedTokens
	r.State = TrialReserved
	r.UsedTokens = 0
	r.CreatedAt = time.Now().UTC()
	r.UpdatedAt = r.CreatedAt
	s.trialAllowances[key] = a
	s.trialReservations[r.ID] = copyTrialReservation(r)
	return copyTrialReservation(r), nil
}

func (s *MemoryStore) GetTrialReservation(ctx context.Context, id string) (TrialReservation, error) {
	if err := ctx.Err(); err != nil {
		return TrialReservation{}, err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	r, ok := s.trialReservations[id]
	if !ok {
		return r, ErrTrialNotFound
	}
	return copyTrialReservation(r), nil
}
func (s *MemoryStore) GetTrialAllowance(ctx context.Context, account, campaign string) (TrialAllowance, error) {
	if err := ctx.Err(); err != nil {
		return TrialAllowance{}, err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	a, ok := s.trialAllowances[trialAllowanceKey{account, campaign}]
	if !ok {
		return a, ErrTrialNotFound
	}
	return a, nil
}
func (s *MemoryStore) MarkTrialDispatched(ctx context.Context, id string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	r, ok := s.trialReservations[id]
	if !ok {
		return ErrTrialNotFound
	}
	if r.State == TrialDispatched {
		return nil
	}
	if r.State != TrialReserved {
		return ErrTrialConflict
	}
	r.State = TrialDispatched
	r.UpdatedAt = time.Now().UTC()
	s.trialReservations[id] = r
	return nil
}
func (s *MemoryStore) ReleaseTrial(ctx context.Context, id string, confirmedUnused bool) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	r, ok := s.trialReservations[id]
	if !ok {
		return ErrTrialNotFound
	}
	if r.State == TrialReleased || r.State == TrialSettled {
		return nil
	}
	if r.State == TrialUnresolved && confirmedUnused {
		return ErrTrialConflict
	}
	if r.State != TrialReserved && !confirmedUnused {
		r.State = TrialUnresolved
		r.UpdatedAt = time.Now().UTC()
		s.trialReservations[id] = r
		return nil
	}
	key := trialAllowanceKey{r.AccountID, r.CampaignID}
	a := s.trialAllowances[key]
	a.ReservedTokens -= r.ReservedTokens
	s.trialAllowances[key] = a
	r.State = TrialReleased
	r.UpdatedAt = time.Now().UTC()
	s.trialReservations[id] = r
	return nil
}
func (s *MemoryStore) SettleTrial(ctx context.Context, id string, settlement TrialSettlement) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	r, ok := s.trialReservations[id]
	if !ok {
		return ErrTrialNotFound
	}
	if r.State == TrialSettled {
		return nil
	}
	if r.State == TrialReleased || r.State == TrialReserved {
		return ErrTrialConflict
	}
	tokens, err := validateTrialSettlement(r, settlement)
	if err != nil {
		r.State = TrialUnresolved
		r.UpdatedAt = time.Now().UTC()
		s.trialReservations[id] = r
		return err
	}
	if e := settlement.Earning; e != nil {
		// Any existing paid-path earning is a conflicting financial identity, not
		// evidence that the rest of this trial transaction has already committed.
		for _, old := range s.providerEarnings {
			if old.JobID == id {
				return ErrTrialConflict
			}
		}
		if s.balances[e.AccountID] > math.MaxInt64-e.AmountMicroUSD || s.withdrawable[e.AccountID] > math.MaxInt64-e.AmountMicroUSD {
			return ErrTrialUnavailable
		}
		cp := *e
		settlement.Earning = &cp
		if err := s.creditProviderAccountLocked(&cp); err != nil {
			return err
		}
	}
	u := settlement.Usage
	u.Timestamp = time.Now().UTC()
	u.CreatedAt = u.Timestamp
	if u.RequestLocation != nil {
		loc := *u.RequestLocation
		u.RequestLocation = &loc
	}
	settlement.Usage = u
	s.usage = append(s.usage, u)
	s.trialSettlements[id] = settlement
	key := trialAllowanceKey{r.AccountID, r.CampaignID}
	a := s.trialAllowances[key]
	a.ReservedTokens -= r.ReservedTokens
	a.UsedTokens += tokens
	s.trialAllowances[key] = a
	r.State = TrialSettled
	r.UsedTokens = tokens
	r.UpdatedAt = time.Now().UTC()
	s.trialReservations[id] = r
	return nil
}

var _ TrialStore = (*MemoryStore)(nil)
