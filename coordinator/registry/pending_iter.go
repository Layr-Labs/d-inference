package registry

// PendingSessionKeys returns the E2E session private keys of every request
// currently pending on this provider (nil entries and requests without a
// session key are skipped). The returned slice is a snapshot: it stays valid
// after the pending map is mutated or cleared.
//
// It exists for the API layer's provider read-loop cleanup: when a provider
// disconnects, Registry.Disconnect wipes the pending map, which would orphan
// every in-flight request's memoized chunk-decryption cache entry. The caller
// collects the keys with this method BEFORE calling Disconnect and forgets
// each one from the cache.
func (p *Provider) PendingSessionKeys() []*[32]byte {
	p.mu.Lock()
	defer p.mu.Unlock()
	keys := make([]*[32]byte, 0, len(p.pendingReqs))
	for _, pr := range p.pendingReqs {
		if pr == nil || pr.SessionPrivKey == nil {
			continue
		}
		keys = append(keys, pr.SessionPrivKey)
	}
	return keys
}
