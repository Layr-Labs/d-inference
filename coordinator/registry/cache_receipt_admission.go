package registry

import "github.com/eigeninference/d-inference/coordinator/protocol"

// CacheReceiptAdmitter resolves the capability used to authenticate a receipt.
// Every call observes current connection, protocol and quarantine state.
type CacheReceiptAdmitter interface {
	Admit(providerID, modelID, tier string) (protocol.PrefixCacheV2Capability, CacheReceiptReason)
}

type CacheReceiptAdmission struct {
	registry *Registry
}

func (admission CacheReceiptAdmission) Admit(providerID, modelID, tier string) (protocol.PrefixCacheV2Capability, CacheReceiptReason) {
	r := admission.registry
	r.mu.RLock()
	provider := r.providers[providerID]
	tracker := r.cacheRouting
	r.mu.RUnlock()
	if provider == nil {
		return protocol.PrefixCacheV2Capability{}, CacheReceiptProviderMissing
	}
	provider.mu.Lock()
	defer provider.mu.Unlock()
	if provider.PrefixCacheProtocol < 2 {
		return protocol.PrefixCacheV2Capability{}, CacheReceiptProtocol
	}
	capability, ok := provider.prefixCacheCapabilityLocked(modelID, tier)
	if !ok || !capability.Enabled || !capability.Ready {
		return protocol.PrefixCacheV2Capability{}, CacheReceiptCapabilityUnavailable
	}
	if tracker != nil &&
		tracker.capabilityRejected(providerID, modelID, tier, capability, tracker.now()) {
		return protocol.PrefixCacheV2Capability{}, CacheReceiptCapabilityFenced
	}
	return capability, CacheReceiptAccepted
}
