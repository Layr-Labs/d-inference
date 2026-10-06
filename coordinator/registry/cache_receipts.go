package registry

import (
	"crypto/rand"
	"encoding/base64"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

const (
	legacyCacheBustPrefix = "darkbloom-uncached-"
	// LegacyCacheBustKeyLength is stable because newCacheReceiptNonce encodes
	// exactly 16 random bytes as 22-byte unpadded base64url.
	LegacyCacheBustKeyLength = len(legacyCacheBustPrefix) + 22
)

func newCacheReceiptNonce() (string, error) {
	var nonce [16]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(nonce[:]), nil
}

// PrepareCacheAttempt requests only protocol-v2 exact proof. Protocol-v0
// providers receive a unique encrypted-body buster; v0/v1 providers otherwise
// remain ordinary serving candidates without cache preference.
func (r *Registry) PrepareCacheAttempt(pr *PendingRequest, provider *Provider) error {
	if r == nil || pr == nil || provider == nil {
		return nil
	}
	provider.mu.Lock()
	protocolVersion := provider.PrefixCacheProtocol
	provider.mu.Unlock()
	if protocolVersion >= 2 && pr.CachePlan.Present() {
		return r.PreparePrefixCacheV2Attempt(pr, provider, pr.CachePlan)
	}
	ticket, open := pr.beginCachePreparation()
	if !open {
		return nil
	}
	if protocolVersion < 1 {
		bust, err := r.newCacheReceiptNonce()
		if err != nil {
			return err
		}
		pr.cacheAttemptMu.Lock()
		if pr.cachePreparation.Accepts(ticket) {
			pr.LegacyCacheBustKey = legacyCacheBustPrefix + bust
		}
		pr.cacheAttemptMu.Unlock()
		return nil
	}
	return nil
}

func (r *Registry) ForgetCacheAttempt(pr *PendingRequest) {
	if r == nil || pr == nil {
		return
	}
	pr.beginCachePreparation()
}

// V1 frames remain decodable during rollback, but never mutate exact routing
// evidence.
func (r *Registry) ApplyPrefixCacheLookup(string, *protocol.PrefixCacheLookupMessage) bool {
	return false
}

func (r *Registry) ApplyPrefixCacheReady(string, *protocol.PrefixCacheReadyMessage) bool {
	return false
}

func (t *cacheRoutingTracker) forgetAttempt(nonce string) {
	if t == nil || nonce == "" {
		return
	}
	t.mu.Lock()
	t.removeAttemptLocked(nonce)
	t.mu.Unlock()
}

func (t *cacheRoutingTracker) markAttemptTerminal(nonce string, now time.Time) {
	if t == nil || nonce == "" {
		return
	}
	t.mu.Lock()
	t.core.MarkAttemptTerminal(nonce, now)
	t.mu.Unlock()
}

func (r *Registry) MarkCacheAttemptTerminal(pr *PendingRequest) {
	if r == nil || pr == nil {
		return
	}
	pr.markCacheAttemptTerminal()
}

func (t *cacheRoutingTracker) disconnect(providerID string, reason cacheHolderRemovalReason) {
	t.invalidateProviderEvidence(providerID, reason, false)
}

func (t *cacheRoutingTracker) invalidateProviderEvidence(providerID string, reason cacheHolderRemovalReason, preserveFences bool) {
	if t == nil {
		return
	}
	t.maintenance.InvalidateProviderEvidence(providerID, reason, preserveFences)
}

func (t *cacheRoutingTracker) invalidateProviderModel(providerID, modelID string, reason cacheHolderRemovalReason) {
	t.invalidateProviderModels(providerID, map[string]cacheHolderRemovalReason{modelID: reason})
}

// Visit this provider's entries once even when a heartbeat changes several
// models. Keep exact-capability proof fences: an unrelated update cannot
// reset quarantine.
func (t *cacheRoutingTracker) invalidateProviderModels(providerID string, models map[string]cacheHolderRemovalReason) {
	if t == nil {
		return
	}
	t.maintenance.InvalidateProviderModels(providerID, models)
}

func (t *cacheRoutingTracker) storeAttemptLocked(nonce string, attempt cacheAttempt) {
	t.core.StoreAttemptLocked(nonce, attempt)
}

func (t *cacheRoutingTracker) removeAttemptLocked(nonce string) {
	t.core.RemoveAttemptLocked(nonce)
}
