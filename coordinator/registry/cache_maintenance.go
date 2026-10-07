package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachetracker"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// CacheMaintainer serializes generation-local maintenance with receipt updates.
type CacheMaintainer interface {
	InvalidateProviderEvidence(string, cachetracker.RemovalReason, bool)
	InvalidateProviderModels(string, map[string]cachetracker.RemovalReason)
	StateCounts(time.Time) (int, int)
	BindChunk(*Provider, map[string]protocol.PrefixCacheV2Capability) bool
}

// CacheMaintenance retains the same generation and mutex as its receipt path.
// It never exposes the underlying evidence directories or their lock.
type CacheMaintenance struct{ tracker *cacheRoutingTracker }

// BindChunk binds one bounded batch. The caller retains provider ownership;
// the persistence directory's own lock makes the empty check cheap.
func (m CacheMaintenance) BindChunk(provider *Provider, capabilities map[string]protocol.PrefixCacheV2Capability) (remaining bool) {
	t := m.tracker
	if t == nil || len(capabilities) == 0 {
		return false
	}
	t.mu.Lock()
	p := t.persister
	t.mu.Unlock()
	if !p.HasPending() {
		return false
	}
	t.mu.Lock()
	remaining = t.bindPendingLocked(provider, capabilities, t.now())
	t.mu.Unlock()
	return remaining
}

func (m CacheMaintenance) InvalidateProviderEvidence(providerID string, reason cachetracker.RemovalReason, preserveFences bool) {
	t := m.tracker
	if t == nil || providerID == "" {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	t.core.InvalidateProviderEvidence(providerID, reason, preserveFences)
}

func (m CacheMaintenance) InvalidateProviderModels(providerID string, models map[string]cachetracker.RemovalReason) {
	t := m.tracker
	if t == nil || providerID == "" || len(models) == 0 {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	t.core.InvalidateProviderModels(providerID, models)
}

// StateCounts releases ownership between bounded expiry passes so a census
// cannot monopolize the receipt path while a large expired index drains.
func (m CacheMaintenance) StateCounts(now time.Time) (holders, attempts int) {
	t := m.tracker
	for pass := 1; ; pass++ {
		t.mu.Lock()
		t.sweepIfDueLocked(now)
		if !t.core.ContinueSweep(pass) {
			holders, attempts = t.holders.Len(), t.attempts.Len()
			t.mu.Unlock()
			return holders, attempts
		}
		t.mu.Unlock()
	}
}
