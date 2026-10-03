package trust

import (
	"context"
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

func (s *Owner) invalidateTrustReuse(seKey string) {
	if s == nil || s.trustReuseCache == nil || seKey == "" {
		return
	}
	// Hard untrust ends the continuity chain immediately and without a final
	// coverage write: the durable tombstone wins and coverage never resurrects.
	s.dropTrustCoverage(seKey)
	revocationEventID := uuid.NewString()
	s.trustReuseCache.invalidateReuse(seKey, revocationEventID)
	if err := s.persistHardUntrustRevocation(seKey, revocationEventID); err != nil {
		s.logger.Warn("trust-reuse: failed to revoke persisted reuse record on hard untrust",
			"error", err, "attempts", trustReuseDeleteAttempts)
	}
}

func (s *Owner) persistHardUntrustRevocation(seKey, revocationEventID string) error {
	s.trustRevocationMu.Lock()
	defer s.trustRevocationMu.Unlock()
	entry := newHardUntrustJournalEntry(seKey, revocationEventID)
	journaled := false
	var journalErr error
	if s.trustReuseJournal != nil {
		entries, err := s.trustReuseJournal.Append(entry)
		if err != nil {
			journalErr = fmt.Errorf("append hard-untrust revocation journal: %w", err)
			s.latchTrustSafety(journalErr)
		} else {
			journaled = true
			s.setPendingHardUntrustEntries(entries)
		}
	}

	st := s.trustReuseCache.store
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
	s.trustReuseCache.installAuthoritativeTrustReuse(authoritative)

	if journaled {
		remaining, err := s.trustReuseJournal.Remove(entry)
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

func (s *Owner) scheduleHardUntrustReplay(
	seKey string,
	entry hardUntrustJournalEntry,
) {
	if s == nil || s.trustReplayCtx == nil ||
		s.trustReuseJournal == nil || s.trustReuseCache == nil {
		return
	}
	key := entry.SEKeySHA256 + "\x00" + entry.RevocationID
	s.trustReplayMu.Lock()
	if _, exists := s.trustReplayInFlight[key]; exists {
		s.trustReplayMu.Unlock()
		return
	}
	s.trustReplayInFlight[key] = struct{}{}
	s.trustReplayMu.Unlock()

	saferun.Go(s.logger, "trustReuseRevocationReplay", func() {
		defer func() {
			s.trustReplayMu.Lock()
			delete(s.trustReplayInFlight, key)
			s.trustReplayMu.Unlock()
		}()
		delay := trustReuseReplayInitialBackoff
		for {
			select {
			case <-s.trustReplayCtx.Done():
				return
			case <-time.After(delay):
			}

			s.trustRevocationMu.Lock()
			st := s.trustReuseCache.store
			if st == nil {
				s.trustRevocationMu.Unlock()
				delay = min(delay*2, 30*time.Second)
				continue
			}
			authoritative, err := s.revokePersistedTrustReuseWithRetry(
				st, seKey, entry.RevocationID,
			)
			if err == nil {
				s.trustReuseCache.installAuthoritativeTrustReuse(authoritative)
				remaining, removeErr := s.trustReuseJournal.Remove(entry)
				if removeErr != nil {
					s.latchTrustSafety(removeErr)
					s.trustRevocationMu.Unlock()
					return
				}
				s.setPendingHardUntrustEntries(remaining)
				if len(remaining) == 0 {
					s.setTrustReplayBlocked(false)
				}
				s.trustRevocationMu.Unlock()
				return
			}
			s.trustRevocationMu.Unlock()
			delay = min(delay*2, 30*time.Second)
		}
	})
}

// revokePersistedTrustReuseWithRetry reuses one stable event identity across all
// bounded attempts and returns the store's authoritative row.
func (s *Owner) revokePersistedTrustReuseWithRetry(st trustReuseStore, seKey, revocationEventID string) (store.ProviderTrustReuse, error) {
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

func revokeProviderTrustReuseOnce(st trustReuseStore, seKey, revocationEventID string) (store.ProviderTrustReuse, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return st.RevokeProviderTrustReuse(ctx, seKey, revocationEventID)
}
