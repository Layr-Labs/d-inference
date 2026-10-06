package memory

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

func (s *MemoryStore) retainDeletedExternalObjectLocked(accountID string, target store.ErasureTarget, externalID string) bool {
	if u := s.usersByAccountID[accountID]; u == nil || u.DeletedAt == nil {
		return false
	}
	if externalID == "" {
		return true
	}
	for _, r := range s.erasureRequests {
		if r.AccountID != accountID || (r.State != store.ErasureErased && r.State != store.ErasurePending) {
			continue
		}
		for _, item := range s.erasureOutbox {
			if item.RequestID == r.ID && item.Target == target && item.ExternalID == externalID && item.State == store.ErasureOutboxPending {
				return true
			}
		}
		now := time.Now()
		s.erasureOutbox = append(s.erasureOutbox, store.ErasureOutboxItem{ID: uuid.NewString(), RequestID: r.ID, Target: target, ExternalID: externalID, HasExternalID: true, State: store.ErasureOutboxPending, NextAt: now, CreatedAt: now})
		return true
	}
	return true
}
