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
	if protocolVersion >= 2 && pr.CachePlan.present() {
		return r.PreparePrefixCacheV2Attempt(pr, provider, pr.CachePlan)
	}
	ticket, open := pr.beginCachePreparation()
	if !open {
		return nil
	}
	if protocolVersion < 1 {
		bust, err := newCacheReceiptNonce()
		if err != nil {
			return err
		}
		pr.cacheAttempt.PublishLegacy(ticket, func() {
			pr.LegacyCacheBustKey = legacyCacheBustPrefix + bust
		})
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

func (r *Registry) MarkCacheAttemptTerminal(pr *PendingRequest) {
	if r == nil || pr == nil {
		return
	}
	pr.markCacheAttemptTerminal(time.Now())
}
