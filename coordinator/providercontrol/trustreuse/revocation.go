package trustreuse

import (
	"context"
	"fmt"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
	"time"
)

const trustReuseDeleteAttempts = 3

var trustReuseDeleteRetryBackoff = 200 * time.Millisecond

// Invalidate drops a device's reuse record in-memory and installs a
// durable tombstone. Wired as the registry's hard-untrust hook, so every
// hard/security deroute (SIP off, Secure Boot off, binary/model-hash change, MDM
// posture mismatch, serial impersonation, bad encrypted chunk, ...) makes "hard
// untrust always takes effect" durable across restarts.
//
// The in-memory invalidation is synchronous and unconditional. Durable
// revocation runs inline with a bounded retry; every attempt carries the one
// event ID generated for this hard-untrust operation. A transient DB blip cannot
// silently leave stale reusable evidence, an ambiguous commit cannot advance the
// generation twice, and a distinct stale-coordinator event cannot collapse into
// an earlier generation.
func (s *Manager) Invalidate(seKey string) {
	if s == nil || s.cache == nil || seKey == "" {
		return
	}
	// Hard untrust ends the continuity chain immediately and without a final
	// coverage write: the durable tombstone wins and coverage never resurrects.
	s.dropTrustCoverage(seKey)
	revocationEventID := uuid.NewString()
	s.cache.invalidateReuse(seKey, revocationEventID)
	if err := s.persistHardUntrustRevocation(seKey, revocationEventID); err != nil {
		s.logger.Warn("trust-reuse: failed to revoke persisted reuse record on hard untrust",
			"error", err, "attempts", trustReuseDeleteAttempts)
	}
}

func (s *Manager) persistHardUntrustRevocation(seKey, revocationEventID string) error {
	s.revocationMu.Lock()
	defer s.revocationMu.Unlock()
	entry := newHardUntrustJournalEntry(seKey, revocationEventID)
	journaled := false
	var journalErr error
	if s.journal != nil {
		entries, err := s.journal.Append(entry)
		if err != nil {
			journalErr = fmt.Errorf("append hard-untrust revocation journal: %w", err)
			s.latchTrustSafety(journalErr)
		} else {
			journaled = true
			s.setPendingHardUntrustEntries(entries)
		}
	}

	st := s.cache.store
	if st == nil {
		if journaled {
			s.setTrustReplayBlocked(true)
		}
		return journalErr
	}
	authoritative, err := s.revokePersistedTrustReuseWithRetry(
		st, seKey, revocationEventID)
	if err != nil {
		s.setTrustReplayBlocked(true)
		if journaled {
			s.scheduleHardUntrustReplay(seKey, entry)
		}
		return fmt.Errorf("revoke persisted trust reuse: %w", err)
	}
	s.cache.installAuthoritativeTrustReuse(authoritative)

	if journaled {
		remaining, err := s.journal.Remove(entry)
		if err != nil {
			cleanupErr := fmt.Errorf("remove durable hard-untrust journal entry: %w", err)
			s.latchTrustSafety(cleanupErr)
			return cleanupErr
		}
		s.setPendingHardUntrustEntries(remaining)
		if len(remaining) == 0 {
			s.setTrustReplayBlocked(false)
		}
	}
	return journalErr
}

// revokePersistedTrustReuseWithRetry reuses one stable event identity across all
// bounded attempts and returns the store's authoritative row.
func (s *Manager) revokePersistedTrustReuseWithRetry(st Store, seKey, revocationEventID string) (store.ProviderTrustReuse, error) {
	var (
		authoritative store.ProviderTrustReuse
		err           error
	)
	for attempt := range trustReuseDeleteAttempts {
		if attempt > 0 {
			time.Sleep(trustReuseDeleteRetryBackoff)
		}
		authoritative, err = revokeProviderTrustReuseOnce(
			st, seKey, revocationEventID)
		if err == nil {
			return authoritative, nil
		}
	}
	return authoritative, err
}

func revokeProviderTrustReuseOnce(st Store, seKey, revocationEventID string) (store.ProviderTrustReuse, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return st.RevokeProviderTrustReuse(ctx, seKey, revocationEventID)
}
