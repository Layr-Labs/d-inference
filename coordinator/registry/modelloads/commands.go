package modelloads

import (
	"sync"
	"time"
)

// Commands owns session-scoped load reservations and their original start times.
// Its mutex is a leaf: callers retain registry/provider ownership where needed,
// and no operation calls into the registry or sends a provider command.
type Commands struct {
	mu      sync.Mutex
	pending map[key]time.Time
	started map[key]time.Time
}

type key struct{ ProviderID, ModelID string }

func NewCommands() Commands {
	return Commands{pending: make(map[key]time.Time), started: make(map[key]time.Time)}
}

// Reserve atomically enforces one pending nonempty-model command per provider.
// Expired entries still block until a sweep removes them, as before.
func (c *Commands) Reserve(providerID, modelID string, now time.Time) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.pending == nil {
		c.pending = make(map[key]time.Time)
	}
	if c.started == nil {
		c.started = make(map[key]time.Time)
	}
	if c.hasProviderLocked(providerID) {
		return false
	}
	k := key{ProviderID: providerID, ModelID: modelID}
	c.pending[k] = now.Add(PendingTTL)
	c.started[k] = now
	return true
}

func (c *Commands) HasProvider(providerID string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.hasProviderLocked(providerID)
}

func (c *Commands) hasProviderLocked(providerID string) bool {
	for key := range c.pending {
		if key.ProviderID == providerID && key.ModelID != "" {
			return true
		}
	}
	return false
}

// Models returns copied identifiers for live policy revalidation. Callers hold
// registry/provider ownership across this observation and RemoveModels.
func (c *Commands) Models(providerID string) []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	var models []string
	for key := range c.pending {
		if key.ProviderID == providerID && key.ModelID != "" {
			models = append(models, key.ModelID)
		}
	}
	return models
}

func (c *Commands) RemoveModels(providerID string, models []string) int {
	c.mu.Lock()
	defer c.mu.Unlock()
	cleared := 0
	for _, modelID := range models {
		k := key{ProviderID: providerID, ModelID: modelID}
		if _, ok := c.pending[k]; ok {
			delete(c.pending, k)
			delete(c.started, k)
			cleared++
		}
	}
	return cleared
}

func (c *Commands) Disconnect(providerID string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for key := range c.pending {
		if key.ProviderID == providerID {
			delete(c.pending, key)
			delete(c.started, key)
		}
	}
}
