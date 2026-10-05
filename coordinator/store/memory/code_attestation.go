package memory

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *MemoryStore) ListCodeAttestations(_ context.Context) ([]store.CodeAttestation, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	out := make([]store.CodeAttestation, 0, len(s.codeAttestations))
	for _, rec := range s.codeAttestations {
		out = append(out, cloneCodeAttestation(rec))
	}
	return out, nil
}

func (s *MemoryStore) UpsertCodeAttestation(_ context.Context, rec store.CodeAttestation) error {
	if rec.SEPubKey == "" {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	if old, ok := s.codeAttestations[rec.SEPubKey]; !ok || !rec.AttestedAt.Before(old.AttestedAt) {
		if ok && sameCodeProof(old, rec) && old.ContinuousCoverageUntil != nil && (rec.ContinuousCoverageUntil == nil || old.ContinuousCoverageUntil.After(*rec.ContinuousCoverageUntil)) {
			rec.ContinuousCoverageUntil = old.ContinuousCoverageUntil
		}
		s.codeAttestations[rec.SEPubKey] = cloneCodeAttestation(rec)
	}
	return nil
}

func (s *MemoryStore) DeleteCodeAttestation(_ context.Context, seKey string) error {
	if seKey == "" {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.codeAttestations, seKey)
	return nil
}

func (s *MemoryStore) ListCodeAttestPushBudgets(_ context.Context) ([]store.CodeAttestPushBudget, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]store.CodeAttestPushBudget, 0, len(s.codeAttestPushBudgets))
	for _, rec := range s.codeAttestPushBudgets {
		out = append(out, rec)
	}
	return out, nil
}

func codeAttestPushBudgetMapKey(seKey, tokenHash string) string {
	return seKey + "\x00" + tokenHash
}

func (s *MemoryStore) UpsertCodeAttestPushBudget(_ context.Context, rec store.CodeAttestPushBudget) error {
	if rec.SEPubKey == "" {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	key := codeAttestPushBudgetMapKey(rec.SEPubKey, rec.TokenHash)
	current, ok := s.codeAttestPushBudgets[key]
	if ok && current.NextPushAt.After(rec.NextPushAt) {
		return nil
	}
	if rec.LastClearAt.IsZero() {
		rec.LastClearAt = current.LastClearAt // never regress the durable clear cooldown
	}
	s.codeAttestPushBudgets[key] = rec
	return nil
}

func (s *MemoryStore) DeleteCodeAttestPushBudget(_ context.Context, seKey string) error {
	if seKey == "" {
		return nil
	}
	s.mu.Lock()
	prefix := seKey + "\x00"
	for key := range s.codeAttestPushBudgets {
		if strings.HasPrefix(key, prefix) {
			delete(s.codeAttestPushBudgets, key)
		}
	}
	s.mu.Unlock()
	return nil
}

func (s *MemoryStore) ReserveCodeAttestPushBudget(
	_ context.Context,
	seKey, tokenHash string,
	now, nextPushAt time.Time,
) (bool, error) {
	if seKey == "" || tokenHash == "" || !nextPushAt.After(now) {
		return false, errors.New("store: invalid code attest push reservation")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	key := codeAttestPushBudgetMapKey(seKey, tokenHash)
	current, ok := s.codeAttestPushBudgets[key]
	if ok && current.NextPushAt.After(now) {
		return false, nil
	}
	floorKey := codeAttestPushBudgetMapKey(seKey, "")
	if !ok {
		// Novel token: admission must additionally clear the per-SE-key floor,
		// so fabricating fresh tokens cannot mint fresh budgets (Codex P1).
		// s.mu serializes floor-check-then-admit here, mirroring the Postgres
		// store, which acquires the floor sentinel row lock before inserting
		// the token row (blue-green double-admission fix).
		if floor, has := s.codeAttestPushBudgets[floorKey]; has &&
			floor.NextPushAt.After(now) {
			return false, nil
		}
	}
	s.codeAttestPushBudgets[key] = store.CodeAttestPushBudget{
		SEPubKey: seKey, TokenHash: tokenHash,
		NextPushAt: nextPushAt, UpdatedAt: now,
	}
	// Every admitted push raises the admission floor for novel tokens. The
	// sentinel's LastClearAt (durable rotation-clear cooldown) is preserved.
	if floor, has := s.codeAttestPushBudgets[floorKey]; !has ||
		nextPushAt.After(floor.NextPushAt) {
		s.codeAttestPushBudgets[floorKey] = store.CodeAttestPushBudget{
			SEPubKey: seKey, NextPushAt: nextPushAt, UpdatedAt: now,
			LastClearAt: floor.LastClearAt,
		}
	}
	s.pruneCodeAttestPushBudgetsLocked(seKey)
	return true, nil
}

// ClearCodeAttestPushFloor drops the per-SE-key novel-token admission floor so
// a genuinely rotated token can be challenged promptly. Per-token cooldown rows
// are untouched (A-B-A retention). The clear is compare-and-set on the
// sentinel's durable LastClearAt: it is honored only when the previous durable
// clear is at least cooldown old, so the anti-abuse spacing between rotation
// clears holds across coordinator restarts and blue-green peers — not just
// within one process. Returns the durable last-clear instant (now when
// honored, the existing one when throttled) and whether the clear was honored.
func (s *MemoryStore) ClearCodeAttestPushFloor(
	_ context.Context, seKey string, now time.Time, cooldown time.Duration,
) (time.Time, bool, error) {
	if seKey == "" {
		return time.Time{}, false, nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	key := codeAttestPushBudgetMapKey(seKey, "")
	if rec, ok := s.codeAttestPushBudgets[key]; ok && !rec.LastClearAt.IsZero() &&
		now.Sub(rec.LastClearAt) < cooldown {
		return rec.LastClearAt, false, nil
	}
	// Keep the sentinel: NextPushAt=now lifts the floor immediately while
	// LastClearAt=now durably starts the next rotation-clear cooldown.
	s.codeAttestPushBudgets[key] = store.CodeAttestPushBudget{
		SEPubKey: seKey, NextPushAt: now, UpdatedAt: now, LastClearAt: now,
	}
	return now, true, nil
}

// pruneCodeAttestPushBudgetsLocked keeps the newest
// CodeAttestPushBudgetMaxTokenRows token rows (never the floor sentinel) for
// one SE key, bounding growth under token churn.
func (s *MemoryStore) pruneCodeAttestPushBudgetsLocked(seKey string) {
	prefix := seKey + "\x00"
	floorKey := codeAttestPushBudgetMapKey(seKey, "")
	type row struct {
		key string
		rec store.CodeAttestPushBudget
	}
	var rows []row
	for key, rec := range s.codeAttestPushBudgets {
		if key != floorKey && strings.HasPrefix(key, prefix) {
			rows = append(rows, row{key, rec})
		}
	}
	for len(rows) > store.CodeAttestPushBudgetMaxTokenRows {
		oldest := 0
		for i, candidate := range rows {
			if codeAttestPushBudgetOlder(candidate.rec, rows[oldest].rec) {
				oldest = i
			}
		}
		delete(s.codeAttestPushBudgets, rows[oldest].key)
		rows[oldest] = rows[len(rows)-1]
		rows = rows[:len(rows)-1]
	}
}

// codeAttestPushBudgetOlder matches the Postgres prune order
// (updated_at DESC, token_hash DESC keeps newest).
func codeAttestPushBudgetOlder(a, b store.CodeAttestPushBudget) bool {
	if !a.UpdatedAt.Equal(b.UpdatedAt) {
		return a.UpdatedAt.Before(b.UpdatedAt)
	}
	return a.TokenHash < b.TokenHash
}
