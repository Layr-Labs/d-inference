package store

import (
	"context"
	"sort"
)

func (s *MemoryStore) ListSandboxCommands(ctx context.Context, accountID, sandboxID string, limit int) ([]SandboxCommandSummary, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	sandbox, exists := s.sandboxes[sandboxID]
	if !exists || sandbox.AccountID != accountID {
		return nil, ErrNotFound
	}
	result := make([]SandboxCommandSummary, 0)
	for _, command := range s.sandboxCommands {
		if command.SandboxID == sandboxID && command.AccountID == accountID {
			result = append(result, sandboxCommandSummary(command))
		}
	}
	sort.Slice(result, func(i, j int) bool {
		if result[i].CreatedAt.Equal(result[j].CreatedAt) {
			return result[i].ID > result[j].ID
		}
		return result[i].CreatedAt.After(result[j].CreatedAt)
	})
	if limit = sandboxListLimit(limit); len(result) > limit {
		result = result[:limit]
	}
	return result, nil
}
