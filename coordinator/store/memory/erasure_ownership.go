package memory

import "github.com/eigeninference/d-inference/coordinator/store"

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
