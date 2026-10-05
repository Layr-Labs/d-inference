package cacheindex

import "iter"

type ProviderIndex[E comparable] struct {
	providers map[string]map[E]struct{}
}

func NewProviderIndex[E comparable]() *ProviderIndex[E] {
	return &ProviderIndex[E]{providers: make(map[string]map[E]struct{})}
}

func (p *ProviderIndex[E]) Store(providerID string, entry E) {
	set := p.providers[providerID]
	if set == nil {
		set = make(map[E]struct{})
		p.providers[providerID] = set
	}
	set[entry] = struct{}{}
}

func (p *ProviderIndex[E]) Delete(providerID string, entry E) {
	set := p.providers[providerID]
	delete(set, entry)
	if len(set) == 0 {
		delete(p.providers, providerID)
	}
}

func (p *ProviderIndex[E]) Contains(providerID string, entry E) bool {
	_, present := p.providers[providerID][entry]
	return present
}
func (p *ProviderIndex[E]) HasProvider(providerID string) bool {
	_, present := p.providers[providerID]
	return present
}
func (p *ProviderIndex[E]) Count(providerID string) int { return len(p.providers[providerID]) }
func (p *ProviderIndex[E]) ProviderCount() int          { return len(p.providers) }

// Deleting the visited member is permitted, matching Go's map iteration rule.
func (p *ProviderIndex[E]) Entries(providerID string) iter.Seq[E] {
	return func(yield func(E) bool) {
		for entry := range p.providers[providerID] {
			if !yield(entry) {
				return
			}
		}
	}
}

func (p *ProviderIndex[E]) Providers() iter.Seq[string] {
	return func(yield func(string) bool) {
		for providerID := range p.providers {
			if !yield(providerID) {
				return
			}
		}
	}
}

func (p *ProviderIndex[E]) Reset() { p.providers = nil }
