package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachetracker"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// settleParkedChunk discards one chunk of the rows parked under (epoch,
// model) because no bind will take them again (the model's SSD capability is
// gone or moved to another cache epoch), settling each durable row against
// the holders still live instead of deleting it outright: with overlapping
// sessions of one machine, a row parked by a disconnected session may still
// be a live session's evidence. It reports whether rows remain; the registry
// re-checks between chunks that the bucket is still one no bind will take
// (dropParkedWhileStale), and a request that needs the tracker lock waits
// for at most one chunk.
func (t *cacheRoutingTracker) settleParkedChunk(epoch, model string) (more bool) {
	if t == nil {
		return false
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.core.SettleParkedChunk(epoch, model)
}

// bindPendingLocked runs under tracker.mu (and the provider's lock, in the
// same order the receipt path uses) whenever a provider's SSD capabilities are
// applied, whether or not they changed: registration already carries them, so
// a reconnecting provider's first apply is an unchanged one. Every parked row
// whose epoch, model, artifact, contract, block-hash version and ready-boundary
// mode match the capability becomes a live holder through the ordinary upsert
// path, so the per-key cap, the expiry heap and the per-provider index all
// apply. A parked row never overwrites a newer live holder the same provider
// already produced, and a row this run already decided to delete is skipped.
// The restoring flag keeps the upsert from re-marking a row the store already
// has.
// cachetracker.BindChunkRows bounds the rows one tracker-lock hold binds, across all of a
// provider's capabilities: a large bucket (one machine owning much of the
// restore) is bound across several holds so cache-participating requests,
// which need the same lock, wait for at most one chunk.
// The result reports whether any capability still has rows parked.
func (t *cacheRoutingTracker) bindPendingLocked(provider *Provider, capabilities map[string]protocol.PrefixCacheV2Capability, now time.Time) (remaining bool) {
	binding := cachetracker.Binding[*Provider]{Provider: provider}
	if provider != nil {
		binding.ProviderID = provider.ID
	}
	return t.core.BindPendingLocked(binding, capabilities, now)
}
