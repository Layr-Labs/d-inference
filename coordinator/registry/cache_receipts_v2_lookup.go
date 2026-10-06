package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachepolicy"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func (t *cacheRoutingTracker) applyLookupV2Decision(
	providerID string,
	provider *Provider,
	capability protocol.PrefixCacheV2Capability,
	msg *protocol.PrefixCacheLookupV2Message,
	routeKey []byte,
	now time.Time,
) CacheReceiptResult {
	if t == nil || !cachepolicy.ValidLookupV2(capability, msg) {
		return rejectCacheReceipt(CacheReceiptInvalid)
	}

	t.mu.Lock()
	defer t.mu.Unlock()
	return t.core.ApplyLookupV2(providerID, provider, capability, msg, routeKey, now)
}
