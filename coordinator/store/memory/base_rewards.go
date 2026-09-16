package memory

import (
	"context"
	"errors"
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

// floorDrawKey is the idempotency key for a per-epoch settlement.
func floorDrawKey(providerKey, epochID string) string {
	return providerKey + "|" + epochID
}

// isOrganicEarning reports whether an earning row counts as organic revenue:
// positive amount and not a base_reward credit.
func isOrganicEarning(e *contracts.ProviderEarning) bool {
	return e.AmountMicroUSD > 0 && e.Model != "base_reward"
}

// SumProviderEarningsByKey returns total organic micro-USD for one provider node
// in [since, until).
func (s *Store) SumProviderEarningsByKey(_ context.Context, providerKey string, since, until time.Time) (int64, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	var total int64
	for i := range s.providerEarnings {
		e := &s.providerEarnings[i]
		if e.ProviderKey != providerKey || !isOrganicEarning(e) {
			continue
		}
		if e.CreatedAt.Before(since) || !e.CreatedAt.Before(until) {
			continue
		}
		total += e.AmountMicroUSD
	}
	return total, nil
}

// SettleProviderFloorDraw inserts the idempotent draw row and, when the row is
// newly inserted with a positive amount, credits the account's balance +
// withdrawable with a LedgerFloorDraw entry. Idempotent on (provider_key,
// epoch_id): a re-settle returns credited=false and changes nothing. A
// zero-amount draw records the audit row but credits nothing.
func (s *Store) SettleProviderFloorDraw(_ context.Context, draw *contracts.ProviderFloorDraw) (bool, error) {
	if draw == nil {
		return false, errors.New("provider floor draw is required")
	}
	if draw.ProviderKey == "" {
		return false, errors.New("provider floor draw provider_key is required")
	}
	if draw.EpochID == "" {
		return false, errors.New("provider floor draw epoch_id is required")
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	key := floorDrawKey(draw.ProviderKey, draw.EpochID)
	if _, exists := s.floorDrawKeys[key]; exists {
		return false, nil // already settled this epoch
	}
	s.floorDrawKeys[key] = struct{}{}

	cp := *draw
	if cp.CreatedAt.IsZero() {
		cp.CreatedAt = time.Now()
	}
	s.floorDrawSeq++
	cp.ID = s.floorDrawSeq
	s.providerFloorDraws = append(s.providerFloorDraws, cp)

	if cp.AmountMicroUSD > 0 {
		s.creditLocked(cp.AccountID, cp.AmountMicroUSD, contracts.LedgerFloorDraw, cp.EpochID, cp.CreatedAt)
		s.withdrawable[cp.AccountID] += cp.AmountMicroUSD
		// Surface the draw in the provider's earnings history/summary. Model
		// "base_reward" keeps it out of organic earning sums while
		// GetAccountEarnings*/GetProviderEarningsSummary (which sum all rows) show
		// it, so the payout isn't an unexplained balance jump in the UI.
		s.providerEarningsSeq++
		s.providerEarnings = append(s.providerEarnings, contracts.ProviderEarning{
			ID:             s.providerEarningsSeq,
			AccountID:      cp.AccountID,
			ProviderKey:    cp.ProviderKey,
			JobID:          "floor:" + cp.EpochID + ":" + cp.ProviderKey,
			Model:          "base_reward",
			AmountMicroUSD: cp.AmountMicroUSD,
			CreatedAt:      cp.CreatedAt,
		})
	}
	return true, nil
}

// SumFloorDrawsForEpoch returns Σ amount_micro_usd settled for an epoch.
func (s *Store) SumFloorDrawsForEpoch(_ context.Context, epochID string) (int64, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	var total int64
	for i := range s.providerFloorDraws {
		if s.providerFloorDraws[i].EpochID == epochID {
			total += s.providerFloorDraws[i].AmountMicroUSD
		}
	}
	return total, nil
}

// ListFloorDrawsForEpoch returns all draw rows for an epoch, largest first.
func (s *Store) ListFloorDrawsForEpoch(_ context.Context, epochID string) ([]contracts.ProviderFloorDraw, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	out := []contracts.ProviderFloorDraw{}
	for i := range s.providerFloorDraws {
		if s.providerFloorDraws[i].EpochID == epochID {
			out = append(out, s.providerFloorDraws[i])
		}
	}
	// Largest amount first (mirrors postgres ORDER BY amount_micro_usd DESC).
	sort.Slice(out, func(i, j int) bool { return out[i].AmountMicroUSD > out[j].AmountMicroUSD })
	return out, nil
}

// ListProviderSessionsOverlapping returns sessions whose lifetime interval
// overlaps [start, end). Closed sessions end at disconnected_at; open sessions
// may overlap via last_seen + openSessionGrace.
func (s *Store) ListProviderSessionsOverlapping(_ context.Context, start, end time.Time, openSessionGrace time.Duration) ([]contracts.ProviderSession, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	out := []contracts.ProviderSession{}
	for i := range s.providerSessions {
		ps := s.providerSessions[i]
		var sessEnd time.Time
		if ps.DisconnectedAt != nil {
			sessEnd = *ps.DisconnectedAt
		} else {
			sessEnd = ps.LastSeen.Add(openSessionGrace)
		}
		// Overlap: connected_at < end AND sessEnd >= start.
		if ps.ConnectedAt.Before(end) && !sessEnd.Before(start) {
			out = append(out, ps)
		}
	}
	// Order by serial_number, connected_at (mirrors postgres ORDER BY).
	sort.Slice(out, func(i, j int) bool { return sessionLess(out[i], out[j]) })
	return out, nil
}

// sessionLess orders by serial_number then connected_at.
func sessionLess(a, b contracts.ProviderSession) bool {
	if a.SerialNumber != b.SerialNumber {
		return a.SerialNumber < b.SerialNumber
	}
	return a.ConnectedAt.Before(b.ConnectedAt)
}

// WithEpochSettlementLock runs fn directly: the memory store is single-process,
// so there is no cross-instance contention to guard against.
func (s *Store) WithEpochSettlementLock(_ context.Context, _ string, fn func() error) error {
	return fn()
}
