package authority

import (
	"context"
	"fmt"
	"time"

	trustjournal "github.com/eigeninference/d-inference/coordinator/internal/provider/journal"
	trustreuse "github.com/eigeninference/d-inference/coordinator/internal/provider/reuse"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

func (s *Service,

) InvalidateTrustReuse(seKey string) {
	if s == nil || s.trustReuseCache == nil || seKey == "" {
		return
	}
	// Hard untrust ends the continuity chain immediately and without a final
	// coverage write: the durable tombstone wins and coverage never resurrects.
	s.DropTrustCoverage(seKey)
	revocationEventID := uuid.NewString()
	s.trustReuseCache.InvalidateReuse(seKey, revocationEventID)
	if err := s.persistHardUntrustRevocation(seKey, revocationEventID); err != nil {
		s.logger.Warn("trust-reuse: failed to revoke persisted reuse record on hard untrust",
			"error", err, "attempts", trustreuse.TrustReuseDeleteAttempts)
	}
}

func (s *Service,

) persistHardUntrustRevocation(seKey, revocationEventID string) error {
	s.trustRevocationMu.Lock()
	defer s.trustRevocationMu.Unlock()
	entry := trustjournal.NewEntry(seKey, revocationEventID)
	journaled := false
	var journalErr error
	if s.trustReuseJournal != nil {
		entries, err := s.trustReuseJournal.Append(entry)
		if err != nil {
			journalErr = fmt.Errorf("append hard-untrust revocation journal: %w", err)
			s.Latch(journalErr)
		} else {
			journaled = true
			s.InstallPendingRevocations(entries)
		}
	}

	st := s.trustReuseCache.Store
	if st == nil {
		if journaled {
			s.SetReplayBlocked(true)
		}
		return journalErr
	}
	authoritative, err := s.revokePersistedTrustReuseWithRetry(
		st, seKey, revocationEventID)
	if err != nil {
		s.SetReplayBlocked(true)
		if journaled {
			s.scheduleHardUntrustReplay(seKey, entry)
		}
		return fmt.Errorf("revoke persisted trust reuse: %w", err)
	}
	s.trustReuseCache.InstallAuthoritativeTrustReuse(authoritative)

	if journaled {
		remaining, err := s.trustReuseJournal.Remove(entry)
		if err != nil {
			cleanupErr := fmt.Errorf("remove durable hard-untrust journal entry: %w", err)
			s.Latch(cleanupErr)
			return cleanupErr
		}
		s.InstallPendingRevocations(remaining)
		if len(remaining) == 0 {
			s.SetReplayBlocked(false)
		}
	}
	return journalErr
}

func (s *Service,

) scheduleHardUntrustReplay(
	seKey string,
	entry trustjournal.Entry,
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
		delay := trustreuse.TrustReuseReplayInitialBackoff
		for {
			select {
			case <-s.trustReplayCtx.Done():
				return
			case <-time.After(delay):
			}

			s.trustRevocationMu.Lock()
			st := s.trustReuseCache.Store
			if st == nil {
				s.trustRevocationMu.Unlock()
				delay = min(delay*2, 30*time.Second)
				continue
			}
			authoritative, err := s.revokePersistedTrustReuseWithRetry(
				st, seKey, entry.RevocationID,
			)
			if err == nil {
				s.trustReuseCache.InstallAuthoritativeTrustReuse(authoritative)
				remaining, removeErr := s.trustReuseJournal.Remove(entry)
				if removeErr != nil {
					s.Latch(removeErr)
					s.trustRevocationMu.Unlock()
					return
				}
				s.InstallPendingRevocations(remaining)
				if len(remaining) == 0 {
					s.SetReplayBlocked(false)
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
func (s *Service,

) revokePersistedTrustReuseWithRetry(st trustreuse.Store, seKey, revocationEventID string) (store.ProviderTrustReuse, error) {
	var (
		authoritative store.ProviderTrustReuse
		err           error
	)
	for attempt := range trustreuse.TrustReuseDeleteAttempts {
		if attempt > 0 {
			time.Sleep(trustreuse.TrustReuseDeleteRetryBackoff)
		}
		authoritative, err = revokeProviderTrustReuseOnce(
			st, seKey, revocationEventID)
		if err == nil {
			return authoritative, nil
		}
	}
	return authoritative, err
}

func revokeProviderTrustReuseOnce(st trustreuse.Store, seKey, revocationEventID string) (store.ProviderTrustReuse, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return st.RevokeProviderTrustReuse(ctx, seKey, revocationEventID)
}
