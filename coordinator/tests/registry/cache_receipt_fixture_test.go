package registry_test

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheplan"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachepolicy"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachetracker"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

type receiptKernelFixture struct{ *cacheIndexKernelFixture }

func newReceiptKernelFixture(ttl time.Duration, maxHolders int) *receiptKernelFixture {
	return &receiptKernelFixture{newCacheIndexKernelFixture(cachetracker.Settings{
		TTL: ttl, MaxHolders: maxHolders, MaxEntries: indexKernelMaxEntries, MaxAttempts: indexKernelMaxAttempts,
	})}
}

// These sequential fixtures keep the original nil connection and route-key
// sentinels. Validation and receipt transitions are the actual production ops.
func (t *receiptKernelFixture) lookup(capability protocol.PrefixCacheV2Capability, msg *protocol.PrefixCacheLookupV2Message, routeKey []byte, now time.Time) production.CacheReceiptResult {
	if !cachepolicy.ValidLookupV2(capability, msg) {
		return cachetracker.RejectCacheReceipt(production.CacheReceiptInvalid)
	}
	return t.ApplyLookupV2("provider", nil, capability, msg, routeKey, now)
}

func (t *receiptKernelFixture) ready(capability protocol.PrefixCacheV2Capability, msg *protocol.PrefixCacheReadyV2Message, routeKey []byte, now time.Time) production.CacheReceiptResult {
	if !cachepolicy.ValidReadyV2(capability, msg) {
		return cachetracker.RejectCacheReceipt(production.CacheReceiptInvalid)
	}
	return t.ApplyReadyV2("provider", nil, capability, msg, routeKey, now, msg.ReadyAnchors[len(msg.ReadyAnchors)-1])
}

type receiptMismatchFlag bool

func (flag *receiptMismatchFlag) Quarantine(cacheplan.Plan) { *flag = true }

func cacheReceiptMismatch(result production.CacheReceiptResult) bool {
	var flag receiptMismatchFlag
	result.ResolveMismatch(&flag)
	return bool(flag)
}

func receiptTestAttempt(tracker *cachetracker.Tracker[*production.Provider], nonce string, capability protocol.PrefixCacheV2Capability, prompt protocol.PrefixCacheAnchor) {
	now := time.Now()
	claims, _ := cacheplan.NewClaims([]protocol.PrefixCacheAnchor{prompt}, capability.BlockSize, prompt)
	tracker.StoreAttemptLocked(nonce, cachetracker.Attempt[*production.Provider]{
		RequestID: "request-" + nonce, ProviderID: "provider", Model: capability.ModelID,
		CreatedAt: now, ExpiresAt: now.Add(time.Minute), V2: true,
		Plan: production.CachePlan{
			ModelAggregateHash: capability.ModelAggregateHash, PromptContractID: capability.PromptContractID,
			CacheScope: "scope", PromptTokenCount: prompt.TokenCount, Boundaries: []protocol.PrefixCacheAnchor{prompt},
		},
		V2Capability: capability, ExpectedPrompt: prompt, ExpectedBoundaries: claims,
	})
}
