package registry

import (
	"github.com/eigeninference/d-inference/coordinator/registry/cachedirectory"
	"io"
	"log/slog"

	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

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
	tracker *cacheRoutingTracker,
	nonce string,
	capability protocol.PrefixCacheV2Capability,
	prompt protocol.PrefixCacheAnchor,
) {
	now := time.Now()

	tracker.directory.RegisterAttempt(nonce, cacheAttempt{
		RequestID:  "request-" + nonce,
		ProviderID: "provider",
		Model:      capability.ModelID,
		CreatedAt:  now,
		ExpiresAt:  now.Add(time.Minute),
		V2:         true,
		Plan: cachedirectory.Plan{
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

func TestValidatePrefixCacheCapabilitiesMixedVersions(t *testing.T) {
	model := protocol.ModelInfo{
		ID:         "model",
		WeightHash: strings.Repeat("a", 64),
	}
	capability := testV2Capability("11111111-1111-1111-1111-111111111111")
	for _, test := range []struct {
		name         string
		version      int
		capabilities []protocol.PrefixCacheV2Capability
		wantError    bool
	}{
		{name: "v0", version: 0},
		{name: "v1", version: 1},
		{name: "v2", version: 2, capabilities: []protocol.PrefixCacheV2Capability{capability}},
		{name: "v1 with v2 data", version: 1, capabilities: []protocol.PrefixCacheV2Capability{capability}, wantError: true},
		{name: "v2 without ready models", version: 2},
		{name: "v2 duplicate", version: 2, capabilities: []protocol.PrefixCacheV2Capability{capability, capability}, wantError: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			_, err := validatePrefixCacheCapabilities(
				test.version,
				test.capabilities,
				map[string]protocol.ModelInfo{model.ID: model})
			if (err != nil) != test.wantError {
				t.Fatalf("error = %v, wantError = %v", err, test.wantError)
			}
		})
	}
	if _, err := uniqueProviderModels([]protocol.ModelInfo{model, model}); err == nil {
		t.Fatal("accepted duplicate registered model")
	}
}

func TestPrefixCacheV2CapabilityEpochChangeClearsEvidence(t *testing.T) {
	registry := New(slog.New(slog.NewTextHandler(io.Discard, nil)))
	oldCapability := testV2Capability("11111111-1111-1111-1111-111111111111")
	newCapability := testV2Capability("22222222-2222-2222-2222-222222222222")
	provider := &Provider{
		ID:                  "provider",
		Models:              []protocol.ModelInfo{{ID: "model", WeightHash: oldCapability.ModelAggregateHash}},
		PrefixCacheProtocol: 2,
		PrefixCacheV2Models: map[string]protocol.PrefixCacheV2Capability{
			"model": oldCapability,
		},
	}
	insertTestProvider(registry, provider)
	prompt := protocol.PrefixCacheAnchor{
		ChainHash:  strings.Repeat("c", 64),
		TokenCount: int(promptcontract.BlockSize),
	}
	testV2Attempt(registry.cacheRouting, "nonce", oldCapability, prompt)
	if !registry.cacheRouting.applyLookupV2(provider.ID, oldCapability, testV2Lookup("nonce", oldCapability, prompt, 4), time.Now()) ||
		!registry.cacheRouting.applyReadyV2(provider.ID, oldCapability, testV2Ready("nonce", oldCapability, prompt, 5), time.Now()) {
		t.Fatal("setup evidence rejected")
	}

	if err := registry.UpdatePrefixCacheCapabilities(
		provider.ID, 2, []protocol.PrefixCacheV2Capability{newCapability}); err != nil {
		t.Fatal(err)
	}

	if registry.cacheRouting.directory.Snapshot().Attempts != 0 ||
		registry.cacheRouting.directory.Snapshot().Sequences != 0 {
		t.Fatalf(
			"epoch refresh retained evidence: attempts=%d sequences=%d",
			registry.cacheRouting.directory.Snapshot().Attempts,
			registry.cacheRouting.directory.Snapshot().Sequences)
	}
	if got := registry.cacheRouting.directory.LifecycleStatus().HolderRemoved[string(cacheHolderRemovalEpochChange)]; got != 1 {
		t.Fatalf("epoch-change holder removals=%d, want 1", got)
	}
}
