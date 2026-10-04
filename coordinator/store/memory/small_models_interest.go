package memory

import (
	"context"
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/store/shared"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *MemoryStore) UpsertSmallModelsInterest(ctx context.Context, record store.SmallModelsInterest) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.usersByAccountID[record.AccountID] == nil {
		return store.ErrNotFound
	}
	now := time.Now().UTC()
	previous, exists := s.smallModelsInterest[record.AccountID]
	record.CreatedAt = now
	if exists {
		record.CreatedAt = previous.CreatedAt
	}
	record.UpdatedAt = now
	s.smallModelsInterest[record.AccountID] = record
	return nil
}

func (s *MemoryStore) GetSmallModelsInterest(ctx context.Context, accountID string) (*store.SmallModelsInterest, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	record, ok := s.smallModelsInterest[accountID]
	if !ok {
		return nil, store.ErrNotFound
	}
	return &record, nil
}

func (s *MemoryStore) ListSmallModelsInterest(ctx context.Context, after string, limit int) ([]store.SmallModelsInterestContact, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	ids := make([]string, 0, len(s.smallModelsInterest))
	for id := range s.smallModelsInterest {
		if id > after {
			ids = append(ids, id)
		}
	}
	sort.Strings(ids)
	if len(ids) > shared.SmallModelsInterestPageLimit(limit) {
		ids = ids[:shared.SmallModelsInterestPageLimit(limit)]
	}
	rows := make([]store.SmallModelsInterestContact, 0, len(ids))
	for _, id := range ids {
		rows = append(rows, store.SmallModelsInterestContact{SmallModelsInterest: s.smallModelsInterest[id], Email: s.usersByAccountID[id].Email})
	}
	return rows, nil
}
