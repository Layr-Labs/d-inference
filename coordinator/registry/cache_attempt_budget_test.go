package registry

import (
	"reflect"
	"strings"
	"testing"
	"time"
	"unsafe"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func budgetTestAttempt() cacheAttempt {
	capability := testV2Capability("11111111-1111-1111-1111-111111111111")
	anchors := []protocol.PrefixCacheAnchor{
		{TokenCount: 256, ChainHash: strings.Repeat("c", 64)},
		{TokenCount: 512, ChainHash: strings.Repeat("d", 64)},
	}
	return cacheAttempt{RequestID: "request-✓", ProviderID: "provider", Model: "model", V2: true,
		CreatedAt: time.Now(), ExpiresAt: time.Now().Add(time.Hour),
		Plan: CachePlan{affinityKey: "affinity", ModelAggregateHash: capability.ModelAggregateHash,
			PromptContractID: capability.PromptContractID, CacheScope: "scope", PromptTokenCount: 513, Boundaries: anchors},
		V2Capability: capability, MemoryCapability: capability, ExpectedPrompt: anchors[1],
		ExpectedBoundaries: map[int]string{256: anchors[0].ChainHash, 512: anchors[1].ChainHash}}
}

// The independent oracle enumerates scalar ownership and discovers every
// capability string by reflection, rather than calling the charging helper.
func expectedBudgetCharge(nonce string, a cacheAttempt) uint64 {
	value := uint64(2048 + 128 + 96*len(a.Plan.Boundaries))
	for _, anchor := range a.Plan.Boundaries {
		value += 2 * uint64(len(anchor.ChainHash))
	}
	for _, scalar := range []string{nonce, a.RequestID, a.ProviderID, a.Model, a.Plan.affinityKey,
		a.Plan.ModelAggregateHash, a.Plan.PromptContractID, a.Plan.CacheScope, a.ExpectedPrompt.ChainHash} {
		value += uint64(len(scalar))
	}
	for _, capability := range []protocol.PrefixCacheV2Capability{a.V2Capability, a.MemoryCapability} {
		r := reflect.ValueOf(capability)
		for i := 0; i < r.NumField(); i++ {
			if r.Field(i).Kind() == reflect.String {
				value += uint64(len(r.Field(i).String()))
			}
		}
	}
	return value
}

func TestCacheAttemptBudgetFormulaAndCheckedArithmetic(t *testing.T) {
	a := budgetTestAttempt()
	got, ok := cacheAttemptCharge("nonce", a)
	if !ok || got != expectedBudgetCharge("nonce", a) {
		t.Fatalf("logical formula = %d/%v, want %d", got, ok, expectedBudgetCharge("nonce", a))
	}
	a.LastReadyAnchor, a.MemoryLastReadyAnchor = a.ExpectedPrompt, a.ExpectedPrompt
	if withReady, valid := cacheAttemptCharge("nonce", a); !valid || withReady != got {
		t.Fatal("READY anchors were not prepaid")
	}
	if _, ok := checkedCacheAttemptAdd(^uint64(0), 1); ok {
		t.Fatal("addition overflow accepted")
	}
	if _, ok := checkedCacheAttemptMultiply(^uint64(0), 2); ok {
		t.Fatal("multiplication overflow accepted")
	}
	if value, ok := checkedCacheAttemptAdd(^uint64(0)-1, 1); !ok || value != ^uint64(0) {
		t.Fatal("exact addition edge rejected")
	}
	if value, ok := checkedCacheAttemptMultiply(0, ^uint64(0)); !ok || value != 0 {
		t.Fatal("zero product rejected")
	}
}

func TestCacheAttemptBudgetExactEdgeReplacementAndRefund(t *testing.T) {
	a := budgetTestAttempt()
	charge := expectedBudgetCharge("first", a)
	tracker := newCacheRoutingTracker(time.Minute, 2)
	tracker.maxAttemptBytes = charge
	tracker.mu.Lock()
	defer tracker.mu.Unlock()
	a.accountedBytes = ^uint64(0) // Caller must not supply its own charge.
	if !tracker.storeAttemptLocked("first", a) || tracker.attemptBytes != charge || tracker.attempts["first"].accountedBytes != charge {
		t.Fatal("exact-edge insertion or immutable charge failed")
	}
	if tracker.storeAttemptLocked("later", a) || len(tracker.attempts) != 1 || tracker.attemptBytes != charge {
		t.Fatal("byte-refused insertion changed retained state")
	}
	before, order := tracker.attempts["first"], *tracker.attemptOrderByNonce["first"]
	more := a
	more.Plan.CacheScope += "x"
	if tracker.storeAttemptLocked("first", more) || !reflect.DeepEqual(tracker.attempts["first"], before) ||
		*tracker.attemptOrderByNonce["first"] != order || tracker.attemptBytes != charge {
		t.Fatal("refused replacement destroyed or discounted the incumbent")
	}
	less := a
	less.Plan.CacheScope = "s"
	want := expectedBudgetCharge("first", less)
	if !tracker.storeAttemptLocked("first", less) || tracker.attemptBytes != want || len(tracker.attemptOrder) != 1 {
		t.Fatal("replacement charge was not old-subtract/new-add")
	}
	tracker.removeAttemptLocked("first")
	tracker.removeAttemptLocked("first")
	if tracker.attemptBytes != 0 || len(tracker.attempts) != 0 || len(tracker.attemptOrder) != 0 {
		t.Fatal("removal did not refund exactly once")
	}
	tracker.maxAttemptBytes = charge - 1
	if tracker.storeAttemptLocked("first", a) || tracker.attemptBytes != 0 {
		t.Fatal("one-byte-under budget admitted record")
	}
	tracker.maxAttemptBytes, tracker.attemptBytes = ^uint64(0), ^uint64(0)-1
	if tracker.storeAttemptLocked("first", a) {
		t.Fatal("total accounting overflow accepted")
	}
}

func TestCacheAttemptBudgetInvalidInputsDoNotPublish(t *testing.T) {
	for _, kind := range []string{"empty_nonce", "duplicate", "wrong_map", "extra_map", "invalid_hash", "invalid_geometry", "wrong_prompt", "oversized_count", "ready_hash"} {
		t.Run(kind, func(t *testing.T) {
			a, nonce := budgetTestAttempt(), "nonce"
			switch kind {
			case "empty_nonce":
				nonce = ""
			case "duplicate":
				a.Plan.Boundaries[0] = a.Plan.Boundaries[1]
				a.ExpectedBoundaries = nil
			case "wrong_map":
				a.ExpectedBoundaries[256] = strings.Repeat("e", 64)
			case "extra_map":
				a.ExpectedBoundaries[768] = strings.Repeat("e", 64)
			case "invalid_hash":
				a.Plan.Boundaries[0].ChainHash = "not-a-digest"
			case "invalid_geometry":
				a.Plan.Boundaries[0].TokenCount = 255
			case "wrong_prompt":
				a.ExpectedPrompt = a.Plan.Boundaries[0]
			case "oversized_count":
				a.Plan.Boundaries = make([]protocol.PrefixCacheAnchor, cacheRoutingMaxReceiptTokens/256+1)
			case "ready_hash":
				a.LastReadyAnchor = protocol.PrefixCacheAnchor{TokenCount: 256, ChainHash: strings.Repeat("f", 65)}
			}
			tracker := newCacheRoutingTracker(time.Minute, 2)
			tracker.mu.Lock()
			defer tracker.mu.Unlock()
			if tracker.storeAttemptLocked(nonce, a) || tracker.attemptBytes != 0 || len(tracker.attempts) != 0 || len(tracker.attemptOrder) != 0 {
				t.Fatal("invalid input retained a record or a charge")
			}
		})
	}
}

func TestCacheAttemptBudgetDetachesAllVariableStorage(t *testing.T) {
	a := budgetTestAttempt()
	// Substrings of one large allocation are legal values, but cannot make the
	// tracker retain that allocation. This test inspects addresses, never mutates
	// Go strings through unsafe memory or claims an allocator/RSS measurement.
	backing := strings.Repeat("a", 1<<20)
	value := backing[16384 : 16384+64]
	a.RequestID, a.ProviderID, a.Model = value, value, value
	a.Plan.affinityKey, a.Plan.ModelAggregateHash = value, value
	a.Plan.PromptContractID, a.Plan.CacheScope = value, value
	for i := range a.Plan.Boundaries {
		a.Plan.Boundaries[i].ChainHash = value
		a.ExpectedBoundaries[a.Plan.Boundaries[i].TokenCount] = value
	}
	a.ExpectedPrompt = a.Plan.Boundaries[1]
	a.LastReadyAnchor, a.MemoryLastReadyAnchor = a.ExpectedPrompt, a.ExpectedPrompt
	for _, capability := range []*protocol.PrefixCacheV2Capability{&a.V2Capability, &a.MemoryCapability} {
		capability.ModelID, capability.ModelAggregateHash, capability.PromptContractID = value, value, value
		capability.BlockHashVersion, capability.CacheEpoch, capability.ReadyBoundaryMode = value, value, value
	}
	tracker := newCacheRoutingTracker(time.Minute, 2)
	tracker.mu.Lock()
	defer tracker.mu.Unlock()
	if !tracker.storeAttemptLocked(value, a) {
		t.Fatal("detachment control was refused")
	}
	owned := tracker.attempts[value]
	check := func(name, s string) {
		t.Helper()
		if s != value || unsafe.StringData(s) == unsafe.StringData(value) {
			t.Errorf("%s retained caller string backing or changed bytes", name)
		}
	}
	for key := range tracker.attempts {
		check("map nonce", key)
	}
	check("heap nonce", tracker.attemptOrder[0].nonce)
	for name, s := range map[string]string{"request": owned.RequestID, "provider": owned.ProviderID, "model": owned.Model,
		"affinity": owned.Plan.affinityKey, "aggregate": owned.Plan.ModelAggregateHash, "contract": owned.Plan.PromptContractID,
		"scope": owned.Plan.CacheScope, "expected": owned.ExpectedPrompt.ChainHash,
		"ready": owned.LastReadyAnchor.ChainHash, "memory_ready": owned.MemoryLastReadyAnchor.ChainHash} {
		check(name, s)
	}
	for _, capability := range []protocol.PrefixCacheV2Capability{owned.V2Capability, owned.MemoryCapability} {
		r := reflect.ValueOf(capability)
		for i := 0; i < r.NumField(); i++ {
			if r.Field(i).Kind() == reflect.String {
				check(r.Type().Field(i).Name, r.Field(i).String())
			}
		}
	}
	for _, anchor := range owned.Plan.Boundaries {
		check("boundary", anchor.ChainHash)
	}
	for _, hash := range owned.ExpectedBoundaries {
		check("expected boundary", hash)
	}
	if &owned.Plan.Boundaries[0] == &a.Plan.Boundaries[0] {
		t.Fatal("boundary slice backing retained")
	}
	a.Plan.Boundaries[0].ChainHash = "caller mutation"
	a.ExpectedBoundaries[256] = "caller mutation"
	if owned.Plan.Boundaries[0].ChainHash != value || owned.ExpectedBoundaries[256] != value {
		t.Fatal("caller mutation changed tracker snapshot")
	}
	if tracker.attemptBytes != expectedBudgetCharge(value, owned) {
		t.Fatal("detached snapshot changed logical accounting")
	}
}
