package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachepolicy"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func (t *cacheRoutingTracker) applyReadyV2Decision(
	providerID string,
	provider *Provider,
	capability protocol.PrefixCacheV2Capability,
	msg *protocol.PrefixCacheReadyV2Message,
	routeKey []byte,
	now time.Time,
) CacheReceiptResult {
	if t == nil || !cachepolicy.ValidReadyV2(capability, msg) {
		return rejectCacheReceipt(CacheReceiptInvalid)
	}
	final := msg.ReadyAnchors[len(msg.ReadyAnchors)-1]

	t.mu.Lock()
	defer t.mu.Unlock()
	return t.core.ApplyReadyV2(providerID, provider, capability, msg, routeKey, now, final)
}
