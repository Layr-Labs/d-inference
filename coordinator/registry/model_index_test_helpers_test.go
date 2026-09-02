package registry

import "testing"

// Test-only registry mutators that keep the per-model provider index in step
// with r.providers / p.Models for providers built by hand (not through
// Register). Production writers sync the index themselves (model_index.go);
// a test that mutates p.Models on a REGISTERED provider calls
// p.syncModelIndexLocked() before releasing p.mu.

// insertTestProvider publishes a hand-built provider and indexes its
// advertised models.
func insertTestProvider(r *Registry, p *Provider) {
	r.mu.Lock()
	defer r.mu.Unlock()
	p.mu.Lock()
	defer p.mu.Unlock()
	r.providers[p.ID] = p
	r.modelIndex.sync(p)
}

// removeTestProvider deletes a provider the way Disconnect does as far as the
// index is concerned (detach, then remove from r.providers).
func removeTestProvider(r *Registry, id string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if p := r.providers[id]; p != nil {
		p.mu.Lock()
		p.detachModelIndexLocked(r)
		p.mu.Unlock()
	}
	delete(r.providers, id)
}

// assertModelIndexConsistent checks the index invariant against a brute-force
// walk of r.providers:
//
//	index[model] == { p ∈ r.providers : model ∈ ids(p.Models) }
//
// plus each live provider's own diff baseline (modelIndexIDs == ids(p.Models)).
func assertModelIndexConsistent(t testing.TB, r *Registry) {
	t.Helper()
	r.mu.RLock()
	defer r.mu.RUnlock()
	expected := make(map[string]map[string]*Provider)
	for _, p := range r.providers {
		p.mu.Lock()
		if p.modelIndexDetached {
			t.Errorf("live provider %s is marked detached", p.ID)
		}
		if !modelIndexIDsMatch(p.modelIndexIDs, p.Models) {
			t.Errorf("provider %s baseline %v does not match models %v", p.ID, p.modelIndexIDs, p.Models)
		}
		for _, m := range p.Models {
			set := expected[m.ID]
			if set == nil {
				set = make(map[string]*Provider)
				expected[m.ID] = set
			}
			set[p.ID] = p
		}
		p.mu.Unlock()
	}
	r.modelIndex.mu.RLock()
	defer r.modelIndex.mu.RUnlock()
	got := r.modelIndex.byModel
	for model, want := range expected {
		have := got[model]
		if len(have) != len(want) {
			t.Errorf("index[%s] has %d providers, brute force %d", model, len(have), len(want))
			continue
		}
		for id, p := range want {
			if have[id] != p {
				t.Errorf("index[%s] missing/mismatched provider %s", model, id)
			}
		}
	}
	for model, have := range got {
		if _, ok := expected[model]; !ok {
			t.Errorf("index has stale model %s with %d providers", model, len(have))
		}
	}
}
