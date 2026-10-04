package authority

import (
	"context"
	"fmt"

	trustjournal "github.com/eigeninference/d-inference/coordinator/internal/provider/journal"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *Service,

) SeedTrustReuseCache(ctx context.Context) error {
	if s == nil || s.trustReuseCache == nil {
		return nil
	}
	s.trustRevocationMu.Lock()
	defer s.trustRevocationMu.Unlock()
	if s.registry != nil {
		s.registry.SetHardUntrustHook(s.InvalidateTrustReuse)
	}
	if err := s.InitializeTrustReuseJournal(); err != nil {
		return err
	}
	if s.store == nil {
		if s.trustReuseJournal != nil {
			entries, err := s.trustReuseJournal.Load()
			if err != nil {
				s.Latch(err)
				return err
			}
			if len(entries) > 0 {
				s.SetReplayBlocked(true)
				return fmt.Errorf("trust-reuse revocation replay requires a durable store")
			}
		}
		return nil
	}
	s.trustReuseCache.Store = s.store

	var journalEntries []trustjournal.Entry
	if s.trustReuseJournal != nil {
		var err error
		journalEntries, err = s.trustReuseJournal.Load()
		if err != nil {
			s.Latch(err)
			return fmt.Errorf("load trust-reuse revocation journal: %w", err)
		}
		s.InstallPendingRevocations(journalEntries)
	}

	rows, err := s.store.ListProviderTrustReuse(ctx)
	if err != nil {
		if len(journalEntries) > 0 {
			s.SetReplayBlocked(true)
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
			if row.SEPubKey == "" || trustjournal.HashSEPublicKey(row.SEPubKey) != entry.SEKeySHA256 {
				continue
			}
			matched = true
			excluded[index] = struct{}{}
			authoritative, err := s.revokePersistedTrustReuseWithRetry(
				s.store, row.SEPubKey, entry.RevocationID)
			if err != nil {
				replayed = false
				if replayErr == nil {
					replayErr = fmt.Errorf("replay hard-untrust revocation: %w", err)
				}
				continue
			}
			s.trustReuseCache.InstallAuthoritativeTrustReuse(authoritative)
		}
		// A hard untrust during a store outage for an identity with no
		// provider_trust_reuse row leaves an entry that matches nothing above.
		// Entries carrying the plaintext SE key create the missing tombstone
		// (RevokeProviderTrustReuse upserts on absence) and converge; legacy
		// digest-only entries stay pending and keep denying via the pending set.
		if !matched && entry.SEPubKey != "" {
			matched = true
			authoritative, err := s.revokePersistedTrustReuseWithRetry(
				s.store, entry.SEPubKey, entry.RevocationID)
			if err != nil {
				replayed = false
				if replayErr == nil {
					replayErr = fmt.Errorf("replay hard-untrust revocation: %w", err)
				}
			} else {
				s.trustReuseCache.InstallAuthoritativeTrustReuse(authoritative)
			}
		}
		if !matched || !replayed {
			continue
		}
		remaining, err := s.trustReuseJournal.Remove(entry)
		if err != nil {
			s.Latch(err)
			if replayErr == nil {
				replayErr = fmt.Errorf("remove replayed trust-reuse revocation: %w", err)
			}
			continue
		}
		s.InstallPendingRevocations(remaining)
	}

	seedRows := make([]store.ProviderTrustReuse, 0, len(rows))
	for index, row := range rows {
		if _, skip := excluded[index]; skip || s.DeniesIdentity(row.SEPubKey) {
			continue
		}
		seedRows = append(seedRows, row)
	}
	if replayErr != nil {
		s.SetReplayBlocked(true)
		return replayErr
	}
	s.SetReplayBlocked(false)
	n := s.trustReuseCache.Seed(seedRows)
	if n > 0 {
		s.logger.Info("trust-reuse: seeded reuse cache from persisted records (survives deploys)", "records", n)
	}
	return nil
}

// providerApplicationBinaryHash resolves the binary measured for this
// connection. A registration hash is authoritative when present. Hashless
// registrations may use fresh application evidence only while it remains
// installed and bound to both the verified SE identity and this provider
// process's current public key.
