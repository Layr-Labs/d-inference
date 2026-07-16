package registry

import (
	"io"
	"log/slog"
	"math"
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
	tracker.mu.Lock()
	tracker.storeAttemptLocked(nonce, cacheAttempt{
		RequestID:  "request-" + nonce,
		ProviderID: "provider",
		Model:      capability.ModelID,
		CreatedAt:  now,
		ExpiresAt:  now.Add(time.Minute),
		V2:         true,
		Plan: CachePlan{
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

func TestPrefixCacheV2RejectsReadyBeforeLookupAndReplay(t *testing.T) {
	tracker := newCacheRoutingTracker(time.Minute, 2)
	capability := testV2Capability("11111111-1111-1111-1111-111111111111")
	prompt := protocol.PrefixCacheAnchor{
		ChainHash:  strings.Repeat("c", 64),
		TokenCount: int(promptcontract.BlockSize),
	}
	testV2Attempt(tracker, "nonce", capability, prompt)

	if tracker.applyReadyV2("provider", capability, testV2Ready(
		"nonce", capability, prompt, 1), time.Now()) {
		t.Fatal("accepted ready before lookup")
	}
	if !tracker.applyLookupV2("provider", capability, testV2Lookup(
		"nonce", capability, prompt, 1), time.Now()) {
		t.Fatal("rejected valid lookup after rejected ready")
	}
	if !tracker.applyReadyV2("provider", capability, testV2Ready(
		"nonce", capability, prompt, 2), time.Now()) {
		t.Fatal("rejected valid ready")
	}
	if tracker.applyReadyV2("provider", capability, testV2Ready(
		"nonce", capability, prompt, 2), time.Now()) {
		t.Fatal("accepted replayed sequence")
	}
}

func TestPrefixCacheV2IdentityProofAndEpochValidation(t *testing.T) {
	tracker := newCacheRoutingTracker(time.Minute, 2)
	oldCapability := testV2Capability("11111111-1111-1111-1111-111111111111")
	newCapability := testV2Capability("22222222-2222-2222-2222-222222222222")
	prompt := protocol.PrefixCacheAnchor{
		ChainHash:  strings.Repeat("c", 64),
		TokenCount: int(promptcontract.BlockSize),
	}
	testV2Attempt(tracker, "old", oldCapability, prompt)
	mismatch := testV2Lookup("old", oldCapability, prompt, 1)
	mismatch.PromptAnchor.ChainHash = strings.Repeat("d", 64)
	if tracker.applyLookupV2("provider", oldCapability, mismatch, time.Now()) {
		t.Fatal("accepted a prompt proof mismatch")
	}
	staleEpoch := testV2Lookup("old", oldCapability, prompt, 1)
	staleEpoch.CacheEpoch = newCapability.CacheEpoch
	if tracker.applyLookupV2("provider", oldCapability, staleEpoch, time.Now()) {
		t.Fatal("accepted a stale attempt under a different epoch")
	}
	if !tracker.applyLookupV2("provider", oldCapability, testV2Lookup(
		"old", oldCapability, prompt, 1), time.Now()) {
		t.Fatal("identity rejection consumed sequence")
	}

	testV2Attempt(tracker, "new", newCapability, prompt)
	if !tracker.applyLookupV2("provider", newCapability, testV2Lookup(
		"new", newCapability, prompt, 1), time.Now()) {
		t.Fatal("new epoch did not receive an independent sequence")
	}
}

func TestPrefixCacheV2Bounds(t *testing.T) {
	capability := testV2Capability("11111111-1111-1111-1111-111111111111")
	prompt := protocol.PrefixCacheAnchor{
		ChainHash:  strings.Repeat("c", 64),
		TokenCount: int(promptcontract.BlockSize),
	}
	for name, mutate := range map[string]func(*protocol.PrefixCacheReadyV2Message){
		"too many anchors": func(message *protocol.PrefixCacheReadyV2Message) {
			message.ReadyAnchors = []protocol.PrefixCacheAnchor{prompt, prompt, prompt}
		},
		"nonfinite stage": func(message *protocol.PrefixCacheReadyV2Message) {
			message.StageMs = math.Inf(1)
		},
		"oversized token count": func(message *protocol.PrefixCacheReadyV2Message) {
			message.ReadyAnchors[0].TokenCount = cacheRoutingMaxReceiptTokens +
				int(promptcontract.BlockSize)
		},
	} {
		t.Run(name, func(t *testing.T) {
			tracker := newCacheRoutingTracker(time.Minute, 2)
			testV2Attempt(tracker, name, capability, prompt)
			if !tracker.applyLookupV2("provider", capability, testV2Lookup(
				name, capability, prompt, 1), time.Now()) {
				t.Fatal("setup lookup rejected")
			}
			message := testV2Ready(name, capability, prompt, 2)
			mutate(message)
			if tracker.applyReadyV2("provider", capability, message, time.Now()) {
				t.Fatal("accepted out-of-bounds ready receipt")
			}
		})
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
	registry.providers[provider.ID] = provider
	prompt := protocol.PrefixCacheAnchor{
		ChainHash:  strings.Repeat("c", 64),
		TokenCount: int(promptcontract.BlockSize),
	}
	testV2Attempt(registry.cacheRouting, "nonce", oldCapability, prompt)
	registry.cacheRouting.v2Sequences[cacheV2SequenceKey{
		ProviderID: provider.ID,
		ModelID:    oldCapability.ModelID,
		CacheEpoch: oldCapability.CacheEpoch,
	}] = 4

	if err := registry.UpdatePrefixCacheCapabilities(
		provider.ID, 2, []protocol.PrefixCacheV2Capability{newCapability}); err != nil {
		t.Fatal(err)
	}
	registry.cacheRouting.mu.Lock()
	defer registry.cacheRouting.mu.Unlock()
	if len(registry.cacheRouting.attempts) != 0 ||
		len(registry.cacheRouting.v2Sequences) != 0 {
		t.Fatalf(
			"epoch refresh retained evidence: attempts=%d sequences=%d",
			len(registry.cacheRouting.attempts),
			len(registry.cacheRouting.v2Sequences))
	}
}
