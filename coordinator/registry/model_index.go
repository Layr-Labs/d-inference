package registry

import (
	"sync"
	"sync/atomic"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// model_index.go — the per-model provider index.
//
// Every fleet walk that serves one request (the reservation scan, the
// capacity preflight, the servability gate and
// the alias routability probe) used to iterate ALL of r.providers and take
// p.mu on each, even though ~90% of a 1,260-provider fleet does not advertise
// the requested model and fails the very first gate. The index maps an
// advertised model id to the providers advertising it, so those walks visit
// only providers that could possibly pass. It prunes NOTHING else: every
// eligibility gate still runs per visited provider exactly as before, and the
// index is keyed purely on advertisement (p.Models), not on catalog, trust,
// status or capacity — so owner self-route to an off-catalog model, dedicated
// families, aliases and every other rule keep working unchanged.
//
// Invariant (pinned by TestModelIndexMatchesBruteForceAfterEveryMutation):
//
//	index[model] == { p ∈ r.providers : model ∈ ids(p.Models) }
//
// Locking. p.Models is written under p.mu, sometimes WITHOUT r.mu
// (MergeProviderModels), so an r.mu-guarded index cannot be kept in step.
// The index has its own mutex, which is always the innermost lock:
//
//   - writers hold p.mu (and maybe r.mu) and take ix.mu briefly (sync);
//   - readers hold r.mu and take ix.mu only to COPY the provider list
//     (providersForModelLocked); they release it before touching any p.mu.
//
// Nothing ever waits for another lock while holding ix.mu, so it cannot take
// part in a cycle. Readers additionally re-check r.providers membership so a
// stale entry could never route to a removed session, and Disconnect sets
// modelIndexDetached under p.mu so a models_update racing the disconnect
// cannot re-insert the session. Heartbeat re-syncs as a backstop against any
// future p.Models writer that forgets to.

// providerModelIndex maps advertised model id → session id → provider. The
// zero value is ready to use (test registries are built as bare literals).
type providerModelIndex struct {
	mu      sync.RWMutex
	byModel map[string]map[string]*Provider
}

// sync brings the index in line with p.Models (or removes p entirely once it
// is detached). Caller holds p.mu. Allocation-free when nothing changed.
func (ix *providerModelIndex) sync(p *Provider) {
	var want []string
	if !p.modelIndexDetached {
		if modelIndexIDsMatch(p.modelIndexIDs, p.Models) {
			return
		}
		want = make([]string, 0, len(p.Models))
		for _, m := range p.Models {
			want = append(want, m.ID)
		}
	} else if len(p.modelIndexIDs) == 0 {
		return
	}
	ix.mu.Lock()
	for _, id := range p.modelIndexIDs {
		if set := ix.byModel[id]; set != nil && set[p.ID] == p {
			delete(set, p.ID)
			if len(set) == 0 {
				delete(ix.byModel, id)
			}
		}
	}
	if len(want) > 0 {
		if ix.byModel == nil {
			ix.byModel = make(map[string]map[string]*Provider)
		}
		for _, id := range want {
			set := ix.byModel[id]
			if set == nil {
				set = make(map[string]*Provider)
				ix.byModel[id] = set
			}
			set[p.ID] = p
		}
	}
	ix.mu.Unlock()
	p.modelIndexIDs = want
}

// providersFor appends every indexed provider for model to buf (in map
// order, i.e. randomized like the former range over r.providers) and returns
// it. The copy is what lets callers take p.mu afterwards without holding ix.mu.
func (ix *providerModelIndex) providersFor(model string, buf []*Provider) []*Provider {
	ix.mu.RLock()
	defer ix.mu.RUnlock()
	set := ix.byModel[model]
	if cap(buf)-len(buf) < len(set) {
		grown := make([]*Provider, len(buf), len(buf)+len(set))
		copy(grown, buf)
		buf = grown
	}
	for _, p := range set {
		buf = append(buf, p)
	}
	return buf
}

// count reports how many providers are indexed for model (tests, sizing).
func (ix *providerModelIndex) count(model string) int {
	ix.mu.RLock()
	defer ix.mu.RUnlock()
	return len(ix.byModel[model])
}

// modelIndexIDsMatch reports whether the indexed id list equals the model
// list's ids, element for element (order-sensitive: a reorder simply resyncs).
func modelIndexIDsMatch(ids []string, models []protocol.ModelInfo) bool {
	if len(ids) != len(models) {
		return false
	}
	for i := range ids {
		if ids[i] != models[i].ID {
			return false
		}
	}
	return true
}

// syncModelIndexLocked re-syncs this provider's index entries from p.Models.
// Every p.Models writer calls it before releasing p.mu; Heartbeat calls it as
// a backstop. No-op for providers that were never registered (p.registry nil).
// Caller holds p.mu.
func (p *Provider) syncModelIndexLocked() {
	if p.registry == nil {
		return
	}
	p.registry.modelIndex.sync(p)
}

// detachModelIndexLocked removes the provider from the index for good: after
// this, sync can only ever remove. Called by Disconnect. Caller holds p.mu.
func (p *Provider) detachModelIndexLocked(r *Registry) {
	p.modelIndexDetached = true
	r.modelIndex.sync(p)
}

// providersForModelLocked returns the live providers advertising model — the
// candidate set every per-request fleet walk iterates. Entries are re-checked
// against r.providers so a stale index entry can never surface a removed
// session. With modelIndexDisabled (tests only) it returns every provider, so
// the walks can be proven identical with and without the index. Caller holds
// r.mu (either mode) and NO p.mu.
func (r *Registry) providersForModelLocked(model string) []*Provider {
	if r.modelIndexDisabled {
		out := make([]*Provider, 0, len(r.providers))
		for _, p := range r.providers {
			out = append(out, p)
		}
		return out
	}
	providers := r.modelIndex.providersFor(model, nil)
	live := providers[:0]
	for _, p := range providers {
		if r.providers[p.ID] == p {
			live = append(live, p)
		}
	}
	return live
}

// modelProviderInc increments the provider count for a model. Must be called
// with r.mu held.
func (r *Registry) modelProviderInc(model string) {
	r.modelProvidersMu.Lock()
	c, ok := r.modelProviders[model]
	if !ok {
		c = &atomic.Int64{}
		r.modelProviders[model] = c
	}
	r.modelProvidersMu.Unlock()
	c.Add(1)
}

// modelProviderDec decrements the provider count for a model. Must be called
// with r.mu held.
func (r *Registry) modelProviderDec(model string) {
	r.modelProvidersMu.Lock()
	c, ok := r.modelProviders[model]
	r.modelProvidersMu.Unlock()
	if ok {
		v := c.Add(-1)
		if v <= 0 {
			r.modelProvidersMu.Lock()
			delete(r.modelProviders, model)
			r.modelProvidersMu.Unlock()
		}
	}
}
