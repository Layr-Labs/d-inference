package trust

import (
	"fmt"
)

func (s *Owner) latchTrustSafety(err error) {
	if s == nil {
		return
	}
	s.trustSafetyMu.Lock()
	s.trustSafetySticky = true
	s.trustSafetyMu.Unlock()
	if s.logger != nil {
		s.logger.Error("trust-reuse safety latch engaged",
			"health_reason", trustSafetyJournalHealthReason,
			"error", err,
		)
	}
}

func (s *Owner) setTrustReplayBlocked(blocked bool) {
	if s == nil {
		return
	}
	s.trustSafetyMu.Lock()
	s.trustSafetyReplayBlocked = blocked
	s.trustSafetyMu.Unlock()
}

func (s *Owner) TrustSafetyStatus() (bool, string) {
	if s == nil {
		return false, ""
	}
	s.trustSafetyMu.RLock()
	defer s.trustSafetyMu.RUnlock()
	if s.trustSafetySticky {
		return true, trustSafetyJournalHealthReason
	}
	if s.trustSafetyReplayBlocked {
		return true, trustSafetyReplayHealthReason
	}
	return false, ""
}

func (s *Owner) setPendingHardUntrustEntries(entries []hardUntrustJournalEntry) {
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

func (s *Owner) trustReuseIdentityPending(seKey string) bool {
	if s == nil || seKey == "" {
		return false
	}
	digest := hashSEPublicKey(seKey)
	s.trustSafetyMu.RLock()
	defer s.trustSafetyMu.RUnlock()
	return s.pendingHardUntrustKeyHashes[digest] > 0
}

// InitializeTrustReuseJournal creates and validates the local durable journal.
// Production calls this through SeedTrustReuseCache before the HTTP listener is
// started.
func (s *Owner) InitializeTrustReuseJournal() error {
	if s == nil || s.trustReuseJournal == nil {
		return nil
	}
	if err := s.trustReuseJournal.Initialize(); err != nil {
		s.latchTrustSafety(err)
		return fmt.Errorf("initialize trust-reuse revocation journal: %w", err)
	}
	if fileJournal, ok := s.trustReuseJournal.(*fileHardUntrustJournal); ok {
		s.trustAuthorityMu.Lock()
		if s.trustAuthority == nil {
			authority, lockErr := acquireTrustAuthorityLock(fileJournal.Path())
			if lockErr != nil {
				s.trustAuthorityMu.Unlock()
				s.latchTrustSafety(lockErr)
				return fmt.Errorf("acquire single trust authority: %w", lockErr)
			}
			s.trustAuthority = authority
		}
		s.trustAuthorityMu.Unlock()
	}
	entries, err := s.trustReuseJournal.Load()
	if err != nil {
		s.latchTrustSafety(err)
		return fmt.Errorf("load trust-reuse revocation journal: %w", err)
	}
	s.setPendingHardUntrustEntries(entries)
	return nil
}

// SeedTrustReuseCache wires durable invalidation on hard untrust, wires the store
// into the trust-reuse cache, and seeds the cache from persisted records at
// startup (DAR-326 Phase 0). This is what makes the reuse cache survive a
// coordinator restart / blue-green deploy so a fresh instance does not re-run a
// fleet-wide live MDM SecurityInfo + APNs verification. Safe to call once during
// server setup. The hard-untrust hook is wired UNCONDITIONALLY (independent of
// store presence) so a hard untrust always drops the in-memory record even under
// the memory-store fallback; persistence + startup seeding are skipped when no
// store is wired. SECURITY: seeding TRUSTS the DB contents — a row that says
// `hardware` is loaded as a fast-skip candidate. That trust is bounded because
// reuseTrust re-validates every row on read behind an always-run live SE challenge
// (re-proving SIP/Secure-Boot posture + binary + identity) and rejects future-
// dated rows, so a stale/wrong-binary/expired/forged row still falls through to a
// full live MDM verify — seeding cannot grant hardware by itself. The write path
// (provider_trust_reuse table) must therefore be guarded like the payment ledger
// (Threat-Model #5): only the coordinator writes it, after a verified live MDM
// pass. SEC-004: a forged localhost MDM webhook that drove a grant would be
// persisted + reseeded here (amplified across restarts); bounded by the
// localhost-only webhook, fully mitigated by authenticating it (tracked separately).
