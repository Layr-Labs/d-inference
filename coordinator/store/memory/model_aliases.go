package memory

import (
	"fmt"
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"github.com/eigeninference/d-inference/coordinator/store/internal/recordutil"
)

func (s *Store) UpsertModelAlias(alias *contracts.ModelAlias) error {
	if alias == nil || alias.AliasID == "" {
		return fmt.Errorf("model alias requires a non-empty alias_id")
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now()
	cp := recordutil.CloneModelAlias(alias)
	if existing, ok := s.modelAliases[alias.AliasID]; ok && !existing.CreatedAt.IsZero() {
		cp.CreatedAt = existing.CreatedAt
	} else if cp.CreatedAt.IsZero() {
		cp.CreatedAt = now
	}
	cp.UpdatedAt = now
	s.modelAliases[alias.AliasID] = &cp
	return nil
}

func (s *Store) GetModelAlias(aliasID string) (*contracts.ModelAlias, bool, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	a, ok := s.modelAliases[aliasID]
	if !ok {
		return nil, false, nil
	}
	cp := recordutil.CloneModelAlias(a)
	return &cp, true, nil
}

func (s *Store) ListModelAliases() ([]contracts.ModelAlias, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	out := make([]contracts.ModelAlias, 0, len(s.modelAliases))
	for _, a := range s.modelAliases {
		out = append(out, recordutil.CloneModelAlias(a))
	}
	sort.Slice(out, func(i, j int) bool { return out[i].AliasID < out[j].AliasID })
	return out, nil
}

func (s *Store) DeleteModelAlias(aliasID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	delete(s.modelAliases, aliasID)
	return nil
}
