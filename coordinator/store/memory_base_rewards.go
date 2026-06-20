package store

// In-memory implementation of the base-rewards store methods (design §8).
// These mirror postgres_base_rewards.go exactly: same organic-earnings filter
// (amount>0, model != base_reward/probe), same idempotent per-epoch settlement,
// same session-overlap semantics, all under the single MemoryStore mutex.

import (
	"context"
	"errors"
	"sort"
	"time"
)

// floorDrawKey is the idempotency key for a per-epoch settlement.
func floorDrawKey(providerKey, epochID string) string {
	return providerKey + "|" + epochID
}

// isOrganicEarning reports whether an earning row counts as organic revenue:
// positive amount and not a base_reward / probe credit.
func isOrganicEarning(e *ProviderEarning) bool {
	return e.AmountMicroUSD > 0 && e.Model != "base_reward" && e.Model != "probe"
}

// SumProviderEarningsByKey returns total organic micro-USD for one provider node
// in [since, until).
func (s *MemoryStore) SumProviderEarningsByKey(_ context.Context, providerKey string, since, until time.Time) (int64, error) {
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

// HasBilledJobSince reports whether a provider node served ≥1 organic, billed
// job since `since`.
func (s *MemoryStore) HasBilledJobSince(_ context.Context, providerKey string, since time.Time) (bool, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	for i := range s.providerEarnings {
		e := &s.providerEarnings[i]
		if e.ProviderKey != providerKey || !isOrganicEarning(e) {
			continue
		}
		if e.CreatedAt.Before(since) {
			continue
		}
		return true, nil
	}
	return false, nil
}

// SettleProviderFloorDraw inserts the idempotent draw row and, when the row is
// newly inserted with a positive amount, credits the account's balance +
// withdrawable with a LedgerFloorDraw entry. Idempotent on (provider_key,
// epoch_id): a re-settle returns credited=false and changes nothing. A
// zero-amount draw records the audit row but credits nothing.
func (s *MemoryStore) SettleProviderFloorDraw(_ context.Context, draw *ProviderFloorDraw) (bool, error) {
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
		s.creditLocked(cp.AccountID, cp.AmountMicroUSD, LedgerFloorDraw, cp.EpochID, cp.CreatedAt)
		s.withdrawable[cp.AccountID] += cp.AmountMicroUSD
		// Surface the draw in the provider's earnings history/summary. Model
		// "base_reward" keeps it out of organic gating (isOrganicEarning) while
		// GetAccountEarnings*/GetProviderEarningsSummary (which sum all rows) show
		// it, so the payout isn't an unexplained balance jump in the UI.
		s.providerEarningsSeq++
		s.providerEarnings = append(s.providerEarnings, ProviderEarning{
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
func (s *MemoryStore) SumFloorDrawsForEpoch(_ context.Context, epochID string) (int64, error) {
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
func (s *MemoryStore) ListFloorDrawsForEpoch(_ context.Context, epochID string) ([]ProviderFloorDraw, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	out := []ProviderFloorDraw{}
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
// [connected_at, COALESCE(disconnected_at, last_seen)] overlaps [start, end).
func (s *MemoryStore) ListProviderSessionsOverlapping(_ context.Context, start, end time.Time) ([]ProviderSession, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	out := []ProviderSession{}
	for i := range s.providerSessions {
		ps := s.providerSessions[i]
		sessEnd := ps.LastSeen
		if ps.DisconnectedAt != nil {
			sessEnd = *ps.DisconnectedAt
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
func sessionLess(a, b ProviderSession) bool {
	if a.SerialNumber != b.SerialNumber {
		return a.SerialNumber < b.SerialNumber
	}
	return a.ConnectedAt.Before(b.ConnectedAt)
}

// RecordProbeResult stores one coordinator correctness-probe outcome (Phase 1).
func (s *MemoryStore) RecordProbeResult(result *ProbeResult) error {
	if result == nil {
		return errors.New("probe result is required")
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	cp := *result
	if cp.CreatedAt.IsZero() {
		cp.CreatedAt = time.Now()
	}
	s.probeResultSeq++
	cp.ID = s.probeResultSeq
	s.probeResults = append(s.probeResults, cp)
	return nil
}

// HasProbeSuccessSince reports whether a provider passed ≥1 probe since `since`.
func (s *MemoryStore) HasProbeSuccessSince(providerKey string, since time.Time) (bool, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	for i := range s.probeResults {
		p := &s.probeResults[i]
		if p.ProviderKey == providerKey && p.Success && !p.CreatedAt.Before(since) {
			return true, nil
		}
	}
	return false, nil
}

// WithEpochSettlementLock runs fn directly: the memory store is single-process,
// so there is no cross-instance contention to guard against.
func (s *MemoryStore) WithEpochSettlementLock(_ context.Context, _ string, fn func() error) error {
	return fn()
}
