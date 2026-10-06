package registry

import "sync"

// ProviderPersistenceOperations performs serialized snapshots and durable writes.
// Registry entry points schedule these transactions asynchronously.
type ProviderPersistenceOperations interface {
	PersistProvider()
	PersistReputation()
}

// ProviderPersistence keeps a connection's incomplete restore unpublished and
// serializes its durable snapshots so older writes cannot land last.
type ProviderPersistence struct {
	pending    bool // guarded by provider.mu
	serial     sync.Mutex
	registry   *Registry
	provider   *Provider
	operations ProviderPersistenceOperations
}

// CanPublishLocked permits reusable identity and reputation publication only
// after restoration completes. The caller must hold the provider's mutex.
func (s *ProviderPersistence) CanPublishLocked() bool {
	return !s.pending
}

func (r *Registry) providerPersistenceFor(p *Provider) ProviderPersistenceOperations {
	p.mu.Lock()
	defer p.mu.Unlock()
	s := &p.persistence
	if s.operations == nil {
		s.registry, s.provider = r, p
		s.operations = s
		if r.providerPersistenceFactory != nil {
			s.operations = r.providerPersistenceFactory(p.ID, s)
		}
	}
	return s.operations
}
