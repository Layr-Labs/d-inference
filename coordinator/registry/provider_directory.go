package registry

import "sync"

// ProviderDirectory owns current connection membership. A registry binds it to
// its membership lock at construction; one directory belongs to one registry.
// Membership alone does not perform connection teardown or publish model state.
type ProviderDirectory struct {
	mu      *sync.RWMutex
	entries map[string]*Provider
}

func (r *Registry) bindProviderDirectory(directory *ProviderDirectory) {
	if directory == nil {
		directory = &ProviderDirectory{}
	}
	if directory.mu != nil {
		panic("provider directory already belongs to a registry")
	}
	directory.mu = &r.mu
	directory.entries = make(map[string]*Provider)
	r.providerDirectory = directory
	// Existing locked readers share the owner's sole map, not a second index.
	r.providers = directory.entries
}

func (d *ProviderDirectory) Load(id string) *Provider {
	d.mu.RLock()
	defer d.mu.RUnlock()
	return d.entries[id]
}

func (d *ProviderDirectory) Store(id string, provider *Provider) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.storeLocked(id, provider)
}

func (d *ProviderDirectory) Delete(id string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.deleteLocked(id)
}

func (d *ProviderDirectory) storeLocked(id string, provider *Provider) {
	d.entries[id] = provider
}

func (d *ProviderDirectory) deleteLocked(id string) { delete(d.entries, id) }
