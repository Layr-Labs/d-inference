package registry_test

import (
	"io"
	"log/slog"
	"math"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachepolicy"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachetracker"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
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
			_, err := cachepolicy.Capabilities(
				test.version,
				test.capabilities,
				map[string]protocol.ModelInfo{model.ID: model})
			if (err != nil) != test.wantError {
				t.Fatalf("error = %v, wantError = %v", err, test.wantError)
			}
		})
	}
	if _, err := cachepolicy.Models([]protocol.ModelInfo{model, model}); err == nil {
		t.Fatal("accepted duplicate registered model")
	}
}

func TestPrefixCacheV2RejectsReadyBeforeLookupAndReplay(t *testing.T) {
	tracker := newReceiptKernelFixture(time.Minute, 2)
	capability := testV2Capability("11111111-1111-1111-1111-111111111111")
	prompt := protocol.PrefixCacheAnchor{
		ChainHash: strings.Repeat("c", 64), TokenCount: int(promptcontract.BlockSize),
	}
	receiptTestAttempt(tracker.Tracker, "nonce", capability, prompt)
	if tracker.ready(capability, fenceTestV2Ready("nonce", capability, prompt, 1), []byte("test-cache-route-key"), time.Now()).Accepted {
		t.Fatal("accepted ready before lookup")
	}
	if !tracker.lookup(capability, fenceTestV2Lookup("nonce", capability, prompt, 1), []byte("test-cache-route-key"), time.Now()).Accepted {
		t.Fatal("rejected valid lookup after rejected ready")
	}
	if !tracker.ready(capability, fenceTestV2Ready("nonce", capability, prompt, 2), []byte("test-cache-route-key"), time.Now()).Accepted {
		t.Fatal("rejected valid ready")
	}
	if tracker.ready(capability, fenceTestV2Ready("nonce", capability, prompt, 2), []byte("test-cache-route-key"), time.Now()).Accepted {
		t.Fatal("accepted replayed sequence")
	}
}

func TestPrefixCacheV2IdentityProofAndEpochValidation(t *testing.T) {
	tracker := newReceiptKernelFixture(time.Minute, 2)
	oldCapability := testV2Capability("11111111-1111-1111-1111-111111111111")
	newCapability := testV2Capability("22222222-2222-2222-2222-222222222222")
	prompt := protocol.PrefixCacheAnchor{
		ChainHash: strings.Repeat("c", 64), TokenCount: int(promptcontract.BlockSize),
	}
	receiptTestAttempt(tracker.Tracker, "old", oldCapability, prompt)
	mismatch := fenceTestV2Lookup("old", oldCapability, prompt, 1)
	mismatch.PromptAnchor.ChainHash = strings.Repeat("d", 64)
	if tracker.lookup(oldCapability, mismatch, []byte("test-cache-route-key"), time.Now()).Accepted {
		t.Fatal("accepted a prompt proof mismatch")
	}
	staleEpoch := fenceTestV2Lookup("old", oldCapability, prompt, 1)
	staleEpoch.CacheEpoch = newCapability.CacheEpoch
	if tracker.lookup(oldCapability, staleEpoch, []byte("test-cache-route-key"), time.Now()).Accepted {
		t.Fatal("accepted a stale attempt under a different epoch")
	}
	if !tracker.lookup(oldCapability, fenceTestV2Lookup("old", oldCapability, prompt, 1), []byte("test-cache-route-key"), time.Now()).Accepted {
		t.Fatal("identity rejection consumed sequence")
	}
	receiptTestAttempt(tracker.Tracker, "new", newCapability, prompt)
	if !tracker.lookup(newCapability, fenceTestV2Lookup("new", newCapability, prompt, 1), []byte("test-cache-route-key"), time.Now()).Accepted {
		t.Fatal("new epoch did not receive an independent sequence")
	}
}

func TestPrefixCacheV2Bounds(t *testing.T) {
	capability := testV2Capability("11111111-1111-1111-1111-111111111111")
	prompt := protocol.PrefixCacheAnchor{
		ChainHash: strings.Repeat("c", 64), TokenCount: int(promptcontract.BlockSize),
	}
	for name, mutate := range map[string]func(*protocol.PrefixCacheReadyV2Message){
		"too many anchors": func(message *protocol.PrefixCacheReadyV2Message) {
			message.ReadyAnchors = []protocol.PrefixCacheAnchor{prompt, prompt, prompt}
		},
		"nonfinite stage": func(message *protocol.PrefixCacheReadyV2Message) {
			message.StageMs = math.Inf(1)
		},
		"oversized token count": func(message *protocol.PrefixCacheReadyV2Message) {
			message.ReadyAnchors[0].TokenCount = cachepolicy.MaxReceiptTokens + int(promptcontract.BlockSize)
		},
	} {
		t.Run(name, func(t *testing.T) {
			tracker := newReceiptKernelFixture(time.Minute, 2)
			receiptTestAttempt(tracker.Tracker, name, capability, prompt)
			if !tracker.lookup(capability, fenceTestV2Lookup(name, capability, prompt, 1), []byte("test-cache-route-key"), time.Now()).Accepted {
				t.Fatal("setup lookup rejected")
			}
			message := fenceTestV2Ready(name, capability, prompt, 2)
			mutate(message)
			if tracker.ready(capability, message, []byte("test-cache-route-key"), time.Now()).Accepted {
				t.Fatal("accepted out-of-bounds ready receipt")
			}
		})
	}
}

func TestPrefixCacheV2CapabilityEpochChangeClearsEvidence(t *testing.T) {
	var tracker *cachetracker.Tracker[*production.Provider]
	var config cachetracker.Config[*production.Provider]
	registry := production.NewWithDependencies(slog.New(slog.NewTextHandler(io.Discard, nil)), production.Dependencies{Cache: production.CacheDependencies{
		Trackers: func(c cachetracker.Config[*production.Provider]) *cachetracker.Tracker[*production.Provider] {
			config, tracker = c, cachetracker.New(c)
			return tracker
		},
	}})
	oldCapability := testV2Capability("11111111-1111-1111-1111-111111111111")
	newCapability := testV2Capability("22222222-2222-2222-2222-222222222222")
	provider := registry.Register("provider", nil, &protocol.RegisterMessage{
		Models:              []protocol.ModelInfo{{ID: "model", WeightHash: oldCapability.ModelAggregateHash}},
		PrefixCacheProtocol: 2, PrefixCacheV2Models: []protocol.PrefixCacheV2Capability{oldCapability},
	})
	prompt := protocol.PrefixCacheAnchor{
		ChainHash: strings.Repeat("c", 64), TokenCount: int(promptcontract.BlockSize),
	}
	receiptTestAttempt(tracker, "nonce", oldCapability, prompt)
	config.Sequences.Store(cachetracker.SequenceKey{ProviderID: provider.ID, ModelID: oldCapability.ModelID, CacheEpoch: oldCapability.CacheEpoch}, 4)
	tracker.UpsertHolderLocked("epoch-holder", cachetracker.Holder[*production.Provider]{
		ProviderID: provider.ID, ModelID: oldCapability.ModelID, CacheEpoch: oldCapability.CacheEpoch,
		UpdatedAt: time.Now(), ExpiresAt: time.Now().Add(time.Minute),
	})
	if err := registry.UpdatePrefixCacheCapabilities(provider.ID, 2, []protocol.PrefixCacheV2Capability{newCapability}); err != nil {
		t.Fatal(err)
	}
	if config.Attempts.Len() != 0 || config.Sequences.Len() != 0 {
		t.Fatalf("epoch refresh retained evidence: attempts=%d sequences=%d", config.Attempts.Len(), config.Sequences.Len())
	}
	_, removed := tracker.HolderLifecycle(nil)
	if got := removed[string(cachetracker.RemovalEpochChange)]; got != 1 {
		t.Fatalf("epoch-change holder removals=%d, want 1", got)
	}
}
