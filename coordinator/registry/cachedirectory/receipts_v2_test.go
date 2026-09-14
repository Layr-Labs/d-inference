package cachedirectory

import (
	"math"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestPrefixCacheV2RejectsReadyBeforeLookupAndReplay(t *testing.T) {
	tracker := newTestDirectory(time.Minute, 2)
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
	tracker := newTestDirectory(time.Minute, 2)
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
			message.ReadyAnchors[0].TokenCount = MaxReceiptTokens +
				int(promptcontract.BlockSize)
		},
	} {
		t.Run(name, func(t *testing.T) {
			tracker := newTestDirectory(time.Minute, 2)
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
