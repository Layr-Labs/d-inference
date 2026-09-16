package trustreuse

const (
	JournalHealthReason = "trust_reuse_revocation_journal_unavailable"
	ReplayHealthReason  = "trust_reuse_revocation_replay_pending"
)

func (s *Manager) latchTrustSafety(err error) {
	if s == nil {
		return
	}
	s.safetyMu.Lock()
	s.safetySticky = true
	s.safetyMu.Unlock()
	if s.logger != nil {
		s.logger.Error("trust-reuse safety latch engaged",
			"health_reason", JournalHealthReason,
			"error", err,
		)
	}
}

func (s *Manager) setTrustReplayBlocked(blocked bool) {
	if s == nil {
		return
	}
	s.safetyMu.Lock()
	s.safetyReplayBlocked = blocked
	s.safetyMu.Unlock()
}

func (s *Manager) SafetyStatus() (bool, string) {
	if s == nil {
		return false, ""
	}
	s.safetyMu.RLock()
	defer s.safetyMu.RUnlock()
	if s.safetySticky {
		return true, JournalHealthReason
	}
	if s.safetyReplayBlocked {
		return true, ReplayHealthReason
	}
	return false, ""
}

func (s *Manager) setPendingHardUntrustEntries(entries []hardUntrustJournalEntry) {
	if s == nil {
		return
	}
	pending := make(map[string]int, len(entries))
	for _, entry := range entries {
		pending[entry.SEKeySHA256]++
	}
	s.safetyMu.Lock()
	s.pendingHardUntrustKeyHashes = pending
	s.safetyMu.Unlock()
}

func (s *Manager) trustReuseIdentityPending(seKey string) bool {
	if s == nil || seKey == "" {
		return false
	}
	digest := hashSEPublicKey(seKey)
	s.safetyMu.RLock()
	defer s.safetyMu.RUnlock()
	return s.pendingHardUntrustKeyHashes[digest] > 0
}
