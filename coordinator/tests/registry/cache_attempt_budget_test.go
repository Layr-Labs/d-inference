package registry_test

import (
	"reflect"
	"strings"
	"testing"
	"time"
	"unsafe"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachedemand"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheplan"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachepolicy"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachetracker"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// The ledger and its byte limit are constructor inputs of the kernel, retained
// here as the actual component the tracker charges.
func budgetTestKernel(maxBytes uint64) *receiptKernelFixture {
	return &receiptKernelFixture{newCacheIndexKernelFixture(
		cachetracker.Settings{TTL: time.Minute, MaxHolders: 2, MaxEntries: indexKernelMaxEntries, MaxAttempts: indexKernelMaxAttempts},
		func(config *cachetracker.Config[*production.Provider]) {
			config.AttemptBudget = cachetracker.NewAttemptBudget(maxBytes)
		})}
}

// A plan's affinity key is assigned by observing repeated demand. Repeating one
// boundary through the real history gives the plan exactly the supplied key.
func budgetTestAffinity(plan production.CachePlan, affinity string) production.CachePlan {
	repeated := plan.RepeatedPrefixTokens
	history := cachedemand.New(1, time.Minute, nil)
	boundary := []cachedemand.Boundary{{Key: affinity, Tokens: 1}}
	now := time.Now()
	plan.ObserveDemand(history, boundary, now)
	plan.ObserveDemand(history, boundary, now)
	plan.RepeatedPrefixTokens = repeated
	return plan
}

// Expected receipt hashes are frozen claims; fixtures derive them as the
// tracker does, from boundaries no deeper than the supplied prompt.
func budgetTestClaims(boundaries []protocol.PrefixCacheAnchor, prompt protocol.PrefixCacheAnchor) *cacheplan.Claims {
	claims, valid := cacheplan.NewClaims(boundaries, promptcontract.BlockSize, prompt)
	if !valid {
		panic("fixture claims rejected")
	}
	return claims
}

func budgetTestAttempt() indexKernelAttempt {
	capability := testV2Capability("11111111-1111-1111-1111-111111111111")
	anchors := []protocol.PrefixCacheAnchor{
		{TokenCount: 256, ChainHash: strings.Repeat("c", 64)},
		{TokenCount: 512, ChainHash: strings.Repeat("d", 64)},
	}
	return indexKernelAttempt{RequestID: "request-✓", ProviderID: "provider", Model: "model", V2: true,
		CreatedAt: time.Now(), ExpiresAt: time.Now().Add(time.Hour),
		Plan: budgetTestAffinity(production.CachePlan{ModelAggregateHash: capability.ModelAggregateHash,
			PromptContractID: capability.PromptContractID, CacheScope: "scope", PromptTokenCount: 513, Boundaries: anchors}, "affinity"),
		V2Capability: capability, MemoryCapability: capability, ExpectedPrompt: anchors[1],
		ExpectedBoundaries: budgetTestClaims(anchors, anchors[1])}
}

// The independent oracle enumerates scalar ownership and discovers every
// capability string by reflection, rather than calling the charging helper.
func expectedBudgetCharge(nonce string, a indexKernelAttempt) uint64 {
	value := uint64(2048 + 128 + 96*len(a.Plan.Boundaries))
	for _, anchor := range a.Plan.Boundaries {
		value += 2 * uint64(len(anchor.ChainHash))
	}
	for _, scalar := range []string{nonce, a.RequestID, a.ProviderID, a.Model, a.Plan.AffinityKey(),
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
	got, ok := cachetracker.CacheAttemptCharge("nonce", a)
	if !ok || got != expectedBudgetCharge("nonce", a) {
		t.Fatalf("logical formula = %d/%v, want %d", got, ok, expectedBudgetCharge("nonce", a))
	}
	a.LastReadyAnchor, a.MemoryLastReadyAnchor = a.ExpectedPrompt, a.ExpectedPrompt
	if withReady, valid := cachetracker.CacheAttemptCharge("nonce", a); !valid || withReady != got {
		t.Fatal("READY anchors were not prepaid")
	}
	if _, ok := cachetracker.CheckedCacheAttemptAdd(^uint64(0), 1); ok {
		t.Fatal("addition overflow accepted")
	}
	if _, ok := cachetracker.CheckedCacheAttemptMultiply(^uint64(0), 2); ok {
		t.Fatal("multiplication overflow accepted")
	}
	if value, ok := cachetracker.CheckedCacheAttemptAdd(^uint64(0)-1, 1); !ok || value != ^uint64(0) {
		t.Fatal("exact addition edge rejected")
	}
	if value, ok := cachetracker.CheckedCacheAttemptMultiply(0, ^uint64(0)); !ok || value != 0 {
		t.Fatal("zero product rejected")
	}
}

func TestCacheAttemptBudgetExactEdgeReplacementAndRefund(t *testing.T) {
	a := budgetTestAttempt()
	charge := expectedBudgetCharge("first", a)
	tracker := budgetTestKernel(charge)
	attempts, order, ledger := tracker.config.Attempts, tracker.config.AttemptOrder, tracker.config.AttemptBudget
	a.AccountedBytes = ^uint64(0) // Caller must not supply its own charge.
	if !tracker.StoreAttemptLocked("first", a) || ledger.Bytes() != charge || attempts.Lookup("first").AccountedBytes != charge {
		t.Fatal("exact-edge insertion or immutable charge failed")
	}
	if tracker.StoreAttemptLocked("later", a) || attempts.Len() != 1 || ledger.Bytes() != charge {
		t.Fatal("byte-refused insertion changed retained state")
	}
	before, entry := attempts.Lookup("first"), *order.Load("first")
	more := a
	more.Plan.CacheScope += "x"
	if tracker.StoreAttemptLocked("first", more) || !reflect.DeepEqual(attempts.Lookup("first"), before) ||
		*order.Load("first") != entry || ledger.Bytes() != charge {
		t.Fatal("refused replacement destroyed or discounted the incumbent")
	}
	less := a
	less.Plan.CacheScope = "s"
	want := expectedBudgetCharge("first", less)
	if !tracker.StoreAttemptLocked("first", less) || ledger.Bytes() != want || order.Len() != 1 {
		t.Fatal("replacement charge was not old-subtract/new-add")
	}
	tracker.RemoveAttemptLocked("first")
	tracker.RemoveAttemptLocked("first")
	if ledger.Bytes() != 0 || attempts.Len() != 0 || order.Len() != 0 {
		t.Fatal("removal did not refund exactly once")
	}
	// The limit is fixed when a ledger is constructed. The emptied tracker is
	// replaced by an empty one whose ledger has the next limit.
	tracker = budgetTestKernel(charge - 1)
	if tracker.StoreAttemptLocked("first", a) || tracker.config.AttemptBudget.Bytes() != 0 {
		t.Fatal("one-byte-under budget admitted record")
	}
	tracker = budgetTestKernel(^uint64(0))
	tracker.config.AttemptBudget.Store(^uint64(0) - 1)
	if tracker.StoreAttemptLocked("first", a) {
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
				wrong := protocol.PrefixCacheAnchor{TokenCount: 256, ChainHash: strings.Repeat("e", 64)}
				a.ExpectedBoundaries = budgetTestClaims([]protocol.PrefixCacheAnchor{wrong, a.Plan.Boundaries[1]}, a.ExpectedPrompt)
			case "extra_map":
				extra := protocol.PrefixCacheAnchor{TokenCount: 768, ChainHash: strings.Repeat("e", 64)}
				a.ExpectedBoundaries = budgetTestClaims([]protocol.PrefixCacheAnchor{a.Plan.Boundaries[0], a.Plan.Boundaries[1], extra}, extra)
			case "invalid_hash":
				a.Plan.Boundaries[0].ChainHash = "not-a-digest"
			case "invalid_geometry":
				a.Plan.Boundaries[0].TokenCount = 255
			case "wrong_prompt":
				a.ExpectedPrompt = a.Plan.Boundaries[0]
			case "oversized_count":
				a.Plan.Boundaries = make([]protocol.PrefixCacheAnchor, cachepolicy.MaxReceiptTokens/256+1)
			case "ready_hash":
				a.LastReadyAnchor = protocol.PrefixCacheAnchor{TokenCount: 256, ChainHash: strings.Repeat("f", 65)}
			}
			tracker := newReceiptKernelFixture(time.Minute, 2)
			if tracker.StoreAttemptLocked(nonce, a) || tracker.config.AttemptBudget.Bytes() != 0 || tracker.config.Attempts.Len() != 0 || tracker.config.AttemptOrder.Len() != 0 {
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
	a.Plan = budgetTestAffinity(a.Plan, value)
	a.Plan.ModelAggregateHash = value
	a.Plan.PromptContractID, a.Plan.CacheScope = value, value
	for i := range a.Plan.Boundaries {
		a.Plan.Boundaries[i].ChainHash = value
	}
	a.ExpectedBoundaries = budgetTestClaims(a.Plan.Boundaries, a.Plan.Boundaries[1])
	a.ExpectedPrompt = a.Plan.Boundaries[1]
	a.LastReadyAnchor, a.MemoryLastReadyAnchor = a.ExpectedPrompt, a.ExpectedPrompt
	for _, capability := range []*protocol.PrefixCacheV2Capability{&a.V2Capability, &a.MemoryCapability} {
		capability.ModelID, capability.ModelAggregateHash, capability.PromptContractID = value, value, value
		capability.BlockHashVersion, capability.CacheEpoch, capability.ReadyBoundaryMode = value, value, value
	}
	tracker := newReceiptKernelFixture(time.Minute, 2)
	if !tracker.StoreAttemptLocked(value, a) {
		t.Fatal("detachment control was refused")
	}
	owned := tracker.config.Attempts.Lookup(value)
	check := func(name, s string) {
		t.Helper()
		if s != value || unsafe.StringData(s) == unsafe.StringData(value) {
			t.Errorf("%s retained caller string backing or changed bytes", name)
		}
	}
	for key := range tracker.config.Attempts.Entries() {
		check("map nonce", key)
	}
	check("heap nonce", tracker.config.AttemptOrder.Head().Key().Nonce)
	for name, s := range map[string]string{"request": owned.RequestID, "provider": owned.ProviderID, "model": owned.Model,
		"affinity": owned.Plan.AffinityKey(), "aggregate": owned.Plan.ModelAggregateHash, "contract": owned.Plan.PromptContractID,
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
	// Frozen claims do not enumerate their hashes. The retained claims must be
	// the tracker's own, binding exactly the detached boundaries.
	if owned.ExpectedBoundaries == a.ExpectedBoundaries || owned.ExpectedBoundaries.Len() != len(owned.Plan.Boundaries) {
		t.Error("expected boundary claims retained caller's claims or changed size")
	}
	for _, anchor := range owned.Plan.Boundaries {
		if !owned.ExpectedBoundaries.Matches(anchor) {
			t.Error("expected boundary claims do not bind the detached boundary")
		}
	}
	if &owned.Plan.Boundaries[0] == &a.Plan.Boundaries[0] {
		t.Fatal("boundary slice backing retained")
	}
	a.Plan.Boundaries[0].ChainHash = "caller mutation"
	if owned.Plan.Boundaries[0].ChainHash != value || !owned.ExpectedBoundaries.Matches(protocol.PrefixCacheAnchor{TokenCount: 256, ChainHash: value}) {
		t.Fatal("caller mutation changed tracker snapshot")
	}
	if tracker.config.AttemptBudget.Bytes() != expectedBudgetCharge(value, owned) {
		t.Fatal("detached snapshot changed logical accounting")
	}
}
