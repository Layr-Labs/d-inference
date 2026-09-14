package cachedirectory

import (
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry/cacheattempt"
)

type testConnection struct{}
type testDirectory struct{ *Directory[*testConnection] }

func newTestDirectory(ttl time.Duration, max int) *testDirectory {
	return &testDirectory{New[*testConnection](&cacheattempt.Generation{}, ttl, max, nil)}
}
func testV2Capability(epoch string) protocol.PrefixCacheV2Capability {
	return protocol.PrefixCacheV2Capability{
		ModelID:            "model",
		ModelAggregateHash: strings.Repeat("a", 64),
		PromptContractID:   strings.Repeat("b", 64),
		BlockHashVersion:   promptcontract.BlockHashVersion,
		BlockSize:          promptcontract.BlockSize,
		CacheEpoch:         epoch,
		Enabled:            true,
		Ready:              true,
	}
}
func testV2Attempt(
	tracker *testDirectory,
	nonce string,
	capability protocol.PrefixCacheV2Capability,
	prompt protocol.PrefixCacheAnchor,
) {
	now := time.Now()
	tracker.mu.Lock()
	tracker.storeAttemptLocked(nonce, Attempt[*testConnection]{
		RequestID:  "request-" + nonce,
		ProviderID: "provider",
		Model:      capability.ModelID,
		CreatedAt:  now,
		ExpiresAt:  now.Add(time.Minute),
		V2:         true,
		Plan: Plan{
			ModelAggregateHash: capability.ModelAggregateHash,
			PromptContractID:   capability.PromptContractID,
			CacheScope:         "scope",
			PromptTokenCount:   prompt.TokenCount,
			Boundaries:         []protocol.PrefixCacheAnchor{prompt},
		},
		V2Capability:       capability,
		ExpectedPrompt:     prompt,
		ExpectedBoundaries: map[int]string{prompt.TokenCount: prompt.ChainHash},
	})
	tracker.mu.Unlock()
}
func testV2Lookup(
	nonce string,
	capability protocol.PrefixCacheV2Capability,
	prompt protocol.PrefixCacheAnchor,
	sequence uint64,
) *protocol.PrefixCacheLookupV2Message {
	return &protocol.PrefixCacheLookupV2Message{
		Type:               protocol.TypePrefixCacheLookupV2,
		RequestID:          "request-" + nonce,
		CacheReceiptNonce:  nonce,
		ModelID:            capability.ModelID,
		ModelAggregateHash: capability.ModelAggregateHash,
		PromptContractID:   capability.PromptContractID,
		CacheEpoch:         capability.CacheEpoch,
		CacheSeq:           sequence,
		PromptAnchor:       prompt,
		Outcome:            "miss_absent",
		Tier:               "ssd",
		StageMs:            1,
	}
}
func testV2Ready(
	nonce string,
	capability protocol.PrefixCacheV2Capability,
	prompt protocol.PrefixCacheAnchor,
	sequence uint64,
) *protocol.PrefixCacheReadyV2Message {
	return &protocol.PrefixCacheReadyV2Message{
		Type:                       protocol.TypePrefixCacheReadyV2,
		RequestID:                  "request-" + nonce,
		CacheReceiptNonce:          nonce,
		ModelID:                    capability.ModelID,
		ModelAggregateHash:         capability.ModelAggregateHash,
		PromptContractID:           capability.PromptContractID,
		CacheEpoch:                 capability.CacheEpoch,
		CacheSeq:                   sequence,
		Outcome:                    "ready",
		Tier:                       "ssd",
		ReadyAnchors:               []protocol.PrefixCacheAnchor{prompt},
		ExpectedPrefillTokensSaved: prompt.TokenCount,
		StageMs:                    2,
	}
}
func (t *testDirectory) applyLookupV2Result(
	providerID string,
	provider *testConnection,
	capability protocol.PrefixCacheV2Capability,
	msg *protocol.PrefixCacheLookupV2Message,
	routeKey []byte,
	now time.Time,
) (bool, bool) {
	result := t.ApplyLookup(providerID, provider, capability, msg, routeKey, now)
	return result.Accepted, result.mismatch
}
func (t *testDirectory) applyReadyV2Result(
	providerID string,
	provider *testConnection,
	capability protocol.PrefixCacheV2Capability,
	msg *protocol.PrefixCacheReadyV2Message,
	routeKey []byte,
	now time.Time,
) (bool, bool) {
	result := t.ApplyReady(providerID, provider, capability, msg, routeKey, now)
	return result.Accepted, result.mismatch
}
func (t *testDirectory) applyLookupV2(
	providerID string,
	capability protocol.PrefixCacheV2Capability,
	msg *protocol.PrefixCacheLookupV2Message,
	now time.Time,
) bool {
	accepted, _ := t.applyLookupV2Result(
		providerID, nil, capability, msg, []byte("test-cache-route-key"), now)
	return accepted
}
func (t *testDirectory) applyReadyV2(
	providerID string,
	capability protocol.PrefixCacheV2Capability,
	msg *protocol.PrefixCacheReadyV2Message,
	now time.Time,
) bool {
	accepted, _ := t.applyReadyV2Result(
		providerID, nil, capability, msg, []byte("test-cache-route-key"), now)
	return accepted
}
