package trustguard

import (
	trustjournal "github.com/eigeninference/d-inference/coordinator/internal/provider/journal"
	trustreuse "github.com/eigeninference/d-inference/coordinator/internal/provider/reuse"
)

func (s *Guard,

) Latch(err error) {
	if s == nil {
		return
	}
	s.trustSafetyMu.Lock()
	s.trustSafetySticky = true
	s.trustSafetyMu.Unlock()
	if s.logger != nil {
		s.logger.Error("trust-reuse safety latch engaged",
			"health_reason", trustreuse.TrustSafetyJournalHealthReason,
			"error", err,
		)
	}
}

func (s *Guard,

) SetReplayBlocked(blocked bool) {
	if s == nil {
		return
	}
	s.trustSafetyMu.Lock()
	s.trustSafetyReplayBlocked = blocked
	s.trustSafetyMu.Unlock()
}

func (s *Guard,

) TrustSafetyStatus() (bool, string) {
	if s == nil {
		return false, ""
	}
	s.trustSafetyMu.RLock()
	defer s.trustSafetyMu.RUnlock()
	if s.trustSafetySticky {
		return true, trustreuse.TrustSafetyJournalHealthReason
	}
	if s.trustSafetyReplayBlocked {
		return true, trustreuse.TrustSafetyReplayHealthReason
	}
	return false, ""
}

func (s *Guard,

) InstallPendingRevocations(entries []trustjournal.Entry) {
	if s == nil {
		return
	}
	pending := make(map[string]int, len(entries))
	for _, entry := range entries {
		pending[entry.SEKeySHA256]++
	}
	s.trustSafetyMu.Lock()
	s.pendingHardUntrustKeyHashes = pending
	s.trustSafetyMu.Unlock()
}

func (s *Guard,

) DeniesIdentity(seKey string) bool {
	if s == nil || seKey == "" {
		return false
	}
	digest := trustjournal.HashSEPublicKey(seKey)
	s.trustSafetyMu.RLock()
	defer s.trustSafetyMu.RUnlock()
	return s.pendingHardUntrustKeyHashes[digest] > 0
}
