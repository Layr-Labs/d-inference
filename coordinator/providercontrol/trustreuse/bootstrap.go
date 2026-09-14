package trustreuse

import (
	"context"
	"fmt"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// InitializeJournal creates and validates the local durable journal.
// Production calls this through Seed before the HTTP listener is
// started.
func (s *Manager) InitializeJournal() error {
	if s == nil || s.journal == nil {
		return nil
	}
	if err := s.journal.Initialize(); err != nil {
		s.latchTrustSafety(err)
		return fmt.Errorf("initialize trust-reuse revocation journal: %w", err)
	}
	if fileJournal, ok := s.journal.(*fileHardUntrustJournal); ok {
		s.authorityMu.Lock()
		if s.authority == nil {
			authority, lockErr := acquireTrustAuthorityLock(fileJournal.Path())
			if lockErr != nil {
				s.authorityMu.Unlock()
				s.latchTrustSafety(lockErr)
				return fmt.Errorf("acquire single trust authority: %w", lockErr)
			}
			s.authority = authority
		}
		s.authorityMu.Unlock()
	}
	entries, err := s.journal.Load()
	if err != nil {
		s.latchTrustSafety(err)
		return fmt.Errorf("load trust-reuse revocation journal: %w", err)
	}
	s.setPendingHardUntrustEntries(entries)
	return nil
}

// Seed wires durable invalidation on hard untrust, wires the store
// into the trust-reuse cache, and seeds the cache from persisted records at
// startup (DAR-326 Phase 0). This is what makes the reuse cache survive a
// coordinator restart / blue-green deploy so a fresh instance does not re-run a
// fleet-wide live MDM SecurityInfo + APNs verification. Safe to call once during
// server setup. The hard-untrust hook is wired UNCONDITIONALLY (independent of
// store presence) so a hard untrust always drops the in-memory record even under
// the memory-store fallback; persistence + startup seeding are skipped when no
// store is wired. SECURITY: seeding TRUSTS the DB contents — a row that says
// `hardware` is loaded as a fast-skip candidate. That trust is bounded because
// reuse re-validates every row on read behind an always-run live SE challenge
// (re-proving SIP/Secure-Boot posture + binary + identity) and rejects future-
// dated rows, so a stale/wrong-binary/expired/forged row still falls through to a
// full live MDM verify — seeding cannot grant hardware by itself. The write path
// (provider_trust_reuse table) must therefore be guarded like the payment ledger
// (Threat-Model #5): only the coordinator writes it, after a verified live MDM
// pass. SEC-004: a forged localhost MDM webhook that drove a grant would be
// persisted + reseeded here (amplified across restarts); bounded by the
// localhost-only webhook, fully mitigated by authenticating it (tracked separately).
func (s *Manager) Seed(ctx context.Context, st Store) error {
	if s == nil || s.cache == nil {
		return nil
	}
	s.revocationMu.Lock()
	defer s.revocationMu.Unlock()
	if s.registry != nil {
		s.registry.SetHardUntrustHook(s.Invalidate)
	}
	if err := s.InitializeJournal(); err != nil {
		return err
	}
	if st == nil {
		if s.journal != nil {
			entries, err := s.journal.Load()
			if err != nil {
				s.latchTrustSafety(err)
				return err
			}
			if len(entries) > 0 {
				s.setTrustReplayBlocked(true)
				return fmt.Errorf("trust-reuse revocation replay requires a durable store")
			}
		}
		return nil
	}
	s.cache.store = st

	var journalEntries []hardUntrustJournalEntry
	if s.journal != nil {
		var err error
		journalEntries, err = s.journal.Load()
		if err != nil {
			s.latchTrustSafety(err)
			return fmt.Errorf("load trust-reuse revocation journal: %w", err)
		}
		s.setPendingHardUntrustEntries(journalEntries)
	}

	rows, err := st.ListProviderTrustReuse(ctx)
	if err != nil {
		if len(journalEntries) > 0 {
			s.setTrustReplayBlocked(true)
			return fmt.Errorf("list trust-reuse rows for revocation replay: %w", err)
		}
		s.logger.Warn("trust-reuse: failed to seed reuse cache from store", "error", err)
		return nil
	}

	excluded := make(map[int]struct{})
	var replayErr error
	for _, entry := range journalEntries {
		matched := false
		replayed := true
		for index, row := range rows {
			if row.SEPubKey == "" || hashSEPublicKey(row.SEPubKey) != entry.SEKeySHA256 {
				continue
			}
			matched = true
			excluded[index] = struct{}{}
			authoritative, err := s.revokePersistedTrustReuseWithRetry(
				st, row.SEPubKey, entry.RevocationID)
			if err != nil {
				replayed = false
				if replayErr == nil {
					replayErr = fmt.Errorf("replay hard-untrust revocation: %w", err)
				}
				continue
			}
			s.cache.installAuthoritativeTrustReuse(authoritative)
		}
		// A hard untrust during a store outage for an identity with no
		// provider_trust_reuse row leaves an entry that matches nothing above.
		// Entries carrying the plaintext SE key create the missing tombstone
		// (RevokeProviderTrustReuse upserts on absence) and converge; legacy
		// digest-only entries stay pending and keep denying via the pending set.
		if !matched && entry.SEPubKey != "" {
			matched = true
			authoritative, err := s.revokePersistedTrustReuseWithRetry(
				st, entry.SEPubKey, entry.RevocationID)
			if err != nil {
				replayed = false
				if replayErr == nil {
					replayErr = fmt.Errorf("replay hard-untrust revocation: %w", err)
				}
			} else {
				s.cache.installAuthoritativeTrustReuse(authoritative)
			}
		}
		if !matched || !replayed {
			continue
		}
		remaining, err := s.journal.Remove(entry)
		if err != nil {
			s.latchTrustSafety(err)
			if replayErr == nil {
				replayErr = fmt.Errorf("remove replayed trust-reuse revocation: %w", err)
			}
			continue
		}
		s.setPendingHardUntrustEntries(remaining)
	}

	seedRows := make([]store.ProviderTrustReuse, 0, len(rows))
	for index, row := range rows {
		if _, skip := excluded[index]; skip || s.trustReuseIdentityPending(row.SEPubKey) {
			continue
		}
		seedRows = append(seedRows, row)
	}
	if replayErr != nil {
		s.setTrustReplayBlocked(true)
		return replayErr
	}
	s.setTrustReplayBlocked(false)
	n := s.cache.seed(seedRows)
	if n > 0 {
		s.logger.Info("trust-reuse: seeded reuse cache from persisted records (survives deploys)", "records", n)
	}
	return nil
}
