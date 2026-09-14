package trustreuse

import (
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"time"
)

const trustReuseReplayInitialBackoff = time.Second

func (s *Manager) scheduleHardUntrustReplay(
	seKey string,
	entry hardUntrustJournalEntry,
) {
	if s == nil || s.replayCtx == nil ||
		s.journal == nil || s.cache == nil {
		return
	}
	key := entry.SEKeySHA256 + "\x00" + entry.RevocationID
	s.replayMu.Lock()
	if _, exists := s.replayInFlight[key]; exists {
		s.replayMu.Unlock()
		return
	}
	s.replayInFlight[key] = struct{}{}
	s.replayMu.Unlock()

	saferun.Go(s.logger, "trustReuseRevocationReplay", func() {
		defer func() {
			s.replayMu.Lock()
			delete(s.replayInFlight, key)
			s.replayMu.Unlock()
		}()
		delay := trustReuseReplayInitialBackoff
		for {
			select {
			case <-s.replayCtx.Done():
				return
			case <-time.After(delay):
			}

			s.revocationMu.Lock()
			st := s.cache.store
			if st == nil {
				s.revocationMu.Unlock()
				delay = min(delay*2, 30*time.Second)
				continue
			}
			authoritative, err := s.revokePersistedTrustReuseWithRetry(
				st, seKey, entry.RevocationID,
			)
			if err == nil {
				s.cache.installAuthoritativeTrustReuse(authoritative)
				remaining, removeErr := s.journal.Remove(entry)
				if removeErr != nil {
					s.latchTrustSafety(removeErr)
					s.revocationMu.Unlock()
					return
				}
				s.setPendingHardUntrustEntries(remaining)
				if len(remaining) == 0 {
					s.setTrustReplayBlocked(false)
				}
				s.revocationMu.Unlock()
				return
			}
			s.revocationMu.Unlock()
			delay = min(delay*2, 30*time.Second)
		}
	})
}
