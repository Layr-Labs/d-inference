package memory

import (
	"encoding/hex"

	"github.com/eigeninference/d-inference/coordinator/internal/store/erasure"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Session ownership survives removal of the mutable provider record.
func (s *MemoryStore) erasedProviderLocked(providerID string) bool {
	if p := s.providerRecords[providerID]; p != nil && s.erasedAccounts[p.AccountID] {
		return true
	}
	for _, session := range s.history.ProviderSessions {
		if session.SessionID == providerID && s.erasedAccounts[session.AccountID] {
			return true
		}
	}
	if s.machineInventory != nil {
		for _, session := range s.machineInventory.Sessions {
			if session.SessionID == providerID && s.erasedAccounts[session.AccountID] {
				return true
			}
		}
	}
	return false
}

func (s *MemoryStore) accountAdmissionLocked(accountID string) error {
	if u := s.usersByAccountID[accountID]; u != nil && u.DeletedAt != nil {
		return store.ErrErasureConflict
	}
	return nil
}

// Personal device writes may continue for a live co-owner of a shared key.
func (s *MemoryStore) erasedSEOwnerLocked(key, account string) bool {
	owners := s.personalSEOwnersLocked(key)
	if account != "" {
		owners[account] = true
	}
	erased, live := false, false
	for owner := range owners {
		if s.erasedAccounts[owner] {
			erased = true
		} else {
			live = true
		}
	}
	return erased && !live
}

func (s *MemoryStore) personalSEOwnersLocked(key string) map[string]bool {
	owners := map[string]bool{}
	for _, p := range s.providerRecords {
		if p.SEPublicKey == key {
			owners[p.AccountID] = true
		}
	}
	digest := erasure.LegacySEDigest(key)
	if s.machineInventory != nil {
		for alias := range s.machineInventory.Aliases {
			if alias.Kind == "legacy_se" && alias.Digest == digest {
				owners[alias.Scope] = true
			}
		}
	}
	for account := range s.erasureSEOwners[digest] {
		owners[account] = true
	}
	return owners
}

// Retain only hashed ownership before the scrub removes inventory aliases.
func (s *MemoryStore) retainErasureSEOwnersLocked(account string) {
	retain := func(digest string) {
		decoded, err := hex.DecodeString(digest)
		if err != nil || len(decoded) != 32 || hex.EncodeToString(decoded) != digest {
			return
		}
		if s.erasureSEOwners[digest] == nil {
			s.erasureSEOwners[digest] = map[string]bool{}
		}
		s.erasureSEOwners[digest][account] = true
	}
	for _, p := range s.providerRecords {
		if p.AccountID == account && p.SEPublicKey != "" {
			retain(erasure.LegacySEDigest(p.SEPublicKey))
		}
	}
	if s.machineInventory != nil {
		for alias := range s.machineInventory.Aliases {
			if alias.Kind == "legacy_se" && alias.Scope == account {
				retain(alias.Digest)
			}
		}
	}
}
