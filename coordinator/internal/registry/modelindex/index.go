// Package modelindex owns advertised-model membership. Its lock is a leaf:
// callers serialize each Membership, and release index reads before locking a
// provider. Values are opaque session identities, not provider state.
package modelindex

import (
	"sync"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Membership is the ordered advertisement baseline for one session. A detached
// membership cannot be revived by a late models update.
type Membership struct {
	ids      []string
	detached bool
}

func (m *Membership) Active() bool { return !m.detached }

// Matches checks the complete ordered baseline without allocating.
func (m *Membership) Matches(models []protocol.ModelInfo) bool {
	if len(m.ids) != len(models) {
		return false
	}
	for i := range m.ids {
		if m.ids[i] != models[i].ID {
			return false
		}
	}
	return true
}

// Index is ready to use at its zero value. A session ID may be reused; removals
// only affect entries whose opaque identity still matches the retiring session.
type Index[T comparable] struct {
	mu      sync.RWMutex
	byModel map[string]map[string]T
}

// Sync reconciles advertisements while the caller holds its membership lock.
// Unchanged advertisements take neither the index lock nor an allocation.
func (ix *Index[T]) Sync(sessionID string, value T, membership *Membership, models []protocol.ModelInfo) {
	var want []string
	if membership.Active() {
		if membership.Matches(models) {
			return
		}
		want = make([]string, 0, len(models))
		for _, model := range models {
			want = append(want, model.ID)
		}
	} else if len(membership.ids) == 0 {
		return
	}
	ix.mu.Lock()
	for _, id := range membership.ids {
		if set := ix.byModel[id]; set != nil && set[sessionID] == value {
			delete(set, sessionID)
			if len(set) == 0 {
				delete(ix.byModel, id)
			}
		}
	}
	if len(want) > 0 {
		if ix.byModel == nil {
			ix.byModel = make(map[string]map[string]T)
		}
		for _, id := range want {
			set := ix.byModel[id]
			if set == nil {
				set = make(map[string]T)
				ix.byModel[id] = set
			}
			set[sessionID] = value
		}
	}
	ix.mu.Unlock()
	membership.ids = want
}

func (ix *Index[T]) Detach(sessionID string, value T, membership *Membership) {
	membership.detached = true
	ix.Sync(sessionID, value, membership, nil)
}

// AppendProviders copies a bucket in unspecified order, releasing the leaf
// lock before the caller accesses any provider state.
func (ix *Index[T]) AppendProviders(model string, buf []T) []T {
	ix.mu.RLock()
	defer ix.mu.RUnlock()
	set := ix.byModel[model]
	if cap(buf)-len(buf) < len(set) {
		grown := make([]T, len(buf), len(buf)+len(set))
		copy(grown, buf)
		buf = grown
	}
	for _, value := range set {
		buf = append(buf, value)
	}
	return buf
}

// Models enumerates advertised keys in unspecified order. The returned slice
// is detached from the index and includes no membership or provider state.
func (ix *Index[T]) Models() []string {
	ix.mu.RLock()
	defer ix.mu.RUnlock()
	models := make([]string, 0, len(ix.byModel))
	for model := range ix.byModel {
		models = append(models, model)
	}
	return models
}
