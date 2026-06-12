package registry

import (
	"testing"
)

func setProviderAccount(p *Provider, accountID string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.AccountID = accountID
}

// TestSelfRouteRoutesOnlyToOwnedProvider verifies that a SelfRouteOnly request
// is served by a provider the requesting account owns, even when a faster
// provider owned by someone else is available.
func TestSelfRouteRoutesOnlyToOwnedProvider(t *testing.T) {
	reg := New(testLogger())
	model := "self-route-model"

	owned := makeSchedulerProvider(t, reg, "owned", model, 40)  // slower
	other := makeSchedulerProvider(t, reg, "other", model, 400) // much faster
	setProviderAccount(owned, "acct-A")
	setProviderAccount(other, "acct-B")

	req := &PendingRequest{
		RequestID:          "req-self",
		Model:              model,
		RequestedMaxTokens: 128,
		SelfRouteOnly:      true,
		OwnerAccountID:     "acct-A",
	}
	selected, decision := reg.ReserveProviderEx(model, req)
	if selected == nil {
		t.Fatal("ReserveProviderEx returned nil for an owned, capable provider")
	}
	if selected.ID != owned.ID {
		t.Fatalf("selected %q, want owned provider %q (must not pick the faster non-owned one)", selected.ID, owned.ID)
	}
	if decision.CandidateCount != 1 {
		t.Fatalf("decision.CandidateCount=%d, want 1 (only the owned provider is a candidate)", decision.CandidateCount)
	}
}

// TestSelfRouteNeverFallsBackToPaid verifies that when the caller owns no
// eligible provider, self-route returns no provider rather than routing to the
// public fleet — the core "free, my machine only, no fallback" guarantee.
func TestSelfRouteNeverFallsBackToPaid(t *testing.T) {
	reg := New(testLogger())
	model := "no-fallback-model"

	// A perfectly good provider exists, but it belongs to a different account.
	other := makeSchedulerProvider(t, reg, "other", model, 200)
	setProviderAccount(other, "acct-B")

	req := &PendingRequest{
		RequestID:          "req-no-fallback",
		Model:              model,
		RequestedMaxTokens: 128,
		SelfRouteOnly:      true,
		OwnerAccountID:     "acct-A",
	}
	selected, decision := reg.ReserveProviderEx(model, req)
	if selected != nil {
		t.Fatalf("selected %q — self-route must never fall back to a provider the caller does not own", selected.ID)
	}
	if decision.CandidateCount != 0 {
		t.Fatalf("decision.CandidateCount=%d, want 0", decision.CandidateCount)
	}

	// Sanity: an unauthenticated (empty) owner must also match nothing.
	req2 := &PendingRequest{RequestID: "req-empty", Model: model, RequestedMaxTokens: 128, SelfRouteOnly: true, OwnerAccountID: ""}
	if selected2, _ := reg.ReserveProviderEx(model, req2); selected2 != nil {
		t.Fatalf("empty owner matched provider %q; want nil", selected2.ID)
	}
}

// TestSelfRouteRelaxesHardwareTrust verifies that a caller's own self_signed
// machine (which a personal Mac would be — no MDM/MDA) is routable to its
// owner under self-route, while still being unroutable to the public fleet and
// to other accounts.
func TestSelfRouteRelaxesHardwareTrust(t *testing.T) {
	reg := New(testLogger()) // default MinTrustLevel == TrustHardware
	model := "trust-relax-model"

	mine := makeSchedulerProvider(t, reg, "mine", model, 100)
	mine.mu.Lock()
	mine.TrustLevel = TrustSelfSigned
	mine.mu.Unlock()
	setProviderAccount(mine, "acct-A")

	// Normal (paid) request: the self_signed provider is below MinTrust and
	// must not be selected.
	normal := &PendingRequest{RequestID: "req-normal", Model: model, RequestedMaxTokens: 128}
	if selected := reg.ReserveProvider(model, normal); selected != nil {
		t.Fatalf("paid request selected self_signed provider %q; hardware-trust gate must hold for the public fleet", selected.ID)
	}

	// Self-route by the owner: trust is relaxed, so the owner reaches their own
	// machine.
	owner := &PendingRequest{RequestID: "req-owner", Model: model, RequestedMaxTokens: 128, SelfRouteOnly: true, OwnerAccountID: "acct-A"}
	selected := reg.ReserveProvider(model, owner)
	if selected == nil {
		t.Fatal("self-route by owner failed to reach their own self_signed machine (trust relaxation not applied)")
	}
	if selected.ID != mine.ID {
		t.Fatalf("selected %q, want %q", selected.ID, mine.ID)
	}

	// A different account's self-route must NOT reach this machine.
	stranger := &PendingRequest{RequestID: "req-stranger", Model: model, RequestedMaxTokens: 128, SelfRouteOnly: true, OwnerAccountID: "acct-B"}
	if selected := reg.ReserveProvider(model, stranger); selected != nil {
		t.Fatalf("acct-B self-route reached acct-A's machine %q; ownership filter breached", selected.ID)
	}
}

// TestSelfRoutePreservesPrivacyGates verifies that trust relaxation does NOT
// relax the privacy-critical gates: an owned machine that is not
// runtime-verified is still unroutable, even to its owner.
func TestSelfRoutePreservesPrivacyGates(t *testing.T) {
	reg := New(testLogger())
	model := "privacy-gate-model"

	mine := makeSchedulerProvider(t, reg, "mine", model, 100)
	mine.mu.Lock()
	mine.TrustLevel = TrustSelfSigned
	mine.RuntimeVerified = false // privacy gate fails
	mine.mu.Unlock()
	setProviderAccount(mine, "acct-A")

	owner := &PendingRequest{RequestID: "req-owner", Model: model, RequestedMaxTokens: 128, SelfRouteOnly: true, OwnerAccountID: "acct-A"}
	if selected := reg.ReserveProvider(model, owner); selected != nil {
		t.Fatalf("selected non-runtime-verified machine %q; privacy gates must never be relaxed", selected.ID)
	}
}

// TestOwnedProviderSummary verifies the pre-flight counters that drive
// self-route error messaging.
func TestOwnedProviderSummary(t *testing.T) {
	reg := New(testLogger())
	model := "summary-model"

	a1 := makeSchedulerProvider(t, reg, "a1", model, 100)
	a2 := makeSchedulerProvider(t, reg, "a2", model, 100)
	b1 := makeSchedulerProvider(t, reg, "b1", model, 100)
	setProviderAccount(a1, "acct-A")
	setProviderAccount(a2, "acct-A")
	setProviderAccount(b1, "acct-B")

	// a2 is offline → counts as linked-but-not-online for acct-A.
	a2.mu.Lock()
	a2.Status = StatusOffline
	a2.mu.Unlock()

	online, serves := reg.OwnedProviderSummary("acct-A", model)
	if online != 1 {
		t.Fatalf("acct-A online=%d, want 1 (a1 online, a2 offline)", online)
	}
	if serves != 1 {
		t.Fatalf("acct-A servesModel=%d, want 1", serves)
	}

	// Unknown model: online still counts, servesModel drops to 0.
	online, serves = reg.OwnedProviderSummary("acct-A", "model-not-served")
	if online != 1 {
		t.Fatalf("acct-A online=%d for unknown model, want 1", online)
	}
	if serves != 0 {
		t.Fatalf("acct-A servesModel=%d for unknown model, want 0", serves)
	}

	// An account with no providers gets zeros.
	if online, serves = reg.OwnedProviderSummary("acct-none", model); online != 0 || serves != 0 {
		t.Fatalf("acct-none summary=(%d,%d), want (0,0)", online, serves)
	}

	// Empty account never matches.
	if online, serves = reg.OwnedProviderSummary("", model); online != 0 || serves != 0 {
		t.Fatalf("empty account summary=(%d,%d), want (0,0)", online, serves)
	}
}

func setProviderPrivateOnly(p *Provider) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.PrivateOnly = true
}

// TestPrivateOnlyProviderExcludedFromPublicFleet verifies that a private-only
// machine serves ONLY its owner's self-route requests: it is invisible to the
// public fleet (routing and capacity), but reachable by its owner.
func TestPrivateOnlyProviderExcludedFromPublicFleet(t *testing.T) {
	reg := New(testLogger())
	model := "private-only-model"

	priv := makeSchedulerProvider(t, reg, "private", model, 100) // TrustHardware
	setProviderAccount(priv, "acct-A")
	setProviderPrivateOnly(priv)

	// Public request: the private-only machine is the only provider, yet it must
	// not be selected — and capacity must report zero candidates.
	publicReq := &PendingRequest{RequestID: "pub", Model: model, RequestedMaxTokens: 128}
	if selected := reg.ReserveProvider(model, publicReq); selected != nil {
		t.Fatalf("public request selected private-only machine %q", selected.ID)
	}
	if cc, _, _ := reg.QuickCapacityCheck(model, 100, 128, RequestTraits{}); cc != 0 {
		t.Fatalf("QuickCapacityCheck candidateCount=%d for a private-only-only fleet, want 0", cc)
	}

	// The owner reaches it via self-route.
	ownerReq := &PendingRequest{RequestID: "own", Model: model, RequestedMaxTokens: 128, SelfRouteOnly: true, OwnerAccountID: "acct-A"}
	selected := reg.ReserveProvider(model, ownerReq)
	if selected == nil {
		t.Fatal("owner self-route failed to reach their own private-only machine")
	}
	if selected.ID != priv.ID {
		t.Fatalf("selected %q, want %q", selected.ID, priv.ID)
	}
}

// TestPreferOwnerPicksOwnedWhenAvailable verifies the prefer-with-fallback mode
// chooses the caller's own machine even when a faster public provider exists.
func TestPreferOwnerPicksOwnedWhenAvailable(t *testing.T) {
	reg := New(testLogger())
	model := "prefer-model"

	owned := makeSchedulerProvider(t, reg, "owned", model, 40)  // slower
	other := makeSchedulerProvider(t, reg, "other", model, 400) // much faster, public
	setProviderAccount(owned, "acct-A")
	setProviderAccount(other, "acct-B")

	req := &PendingRequest{
		RequestID:          "req-prefer",
		Model:              model,
		RequestedMaxTokens: 128,
		PreferOwner:        true,
		OwnerAccountID:     "acct-A",
	}
	selected, decision := reg.ReserveProviderEx(model, req)
	if selected == nil {
		t.Fatal("prefer returned nil despite an owned, capable provider")
	}
	if selected.ID != owned.ID {
		t.Fatalf("selected %q, want owned %q (prefer must pick own machine over a faster public one)", selected.ID, owned.ID)
	}
	// Both providers are eligible candidates; prefer just narrows the WINNER.
	if decision.CandidateCount != 2 {
		t.Fatalf("decision.CandidateCount=%d, want 2 (public provider is still an eligible fallback)", decision.CandidateCount)
	}
}

// TestPreferOwnerFallsBackToPublic verifies prefer routes to the paid fleet when
// the caller owns no eligible provider — unlike exclusive self-route, which
// returns nil. This is the "never a dead end" guarantee.
func TestPreferOwnerFallsBackToPublic(t *testing.T) {
	reg := New(testLogger())
	model := "prefer-fallback-model"

	other := makeSchedulerProvider(t, reg, "other", model, 200) // public, not owned
	setProviderAccount(other, "acct-B")

	req := &PendingRequest{
		RequestID:          "req-prefer-fb",
		Model:              model,
		RequestedMaxTokens: 128,
		PreferOwner:        true,
		OwnerAccountID:     "acct-A", // owns nothing
	}
	selected, _ := reg.ReserveProviderEx(model, req)
	if selected == nil {
		t.Fatal("prefer returned nil; it must fall back to the public fleet")
	}
	if selected.ID != other.ID {
		t.Fatalf("selected %q, want public fallback %q", selected.ID, other.ID)
	}
}

// TestPreferOwnerRelaxesTrustForOwnMachineOnly verifies the per-provider trust
// relaxation: an un-enrolled OWNED machine is selected under prefer, but an
// un-enrolled PUBLIC machine of the same low trust is not.
func TestPreferOwnerRelaxesTrustForOwnMachineOnly(t *testing.T) {
	reg := New(testLogger())
	reg.MinTrustLevel = TrustHardware
	model := "prefer-trust-model"

	owned := makeSchedulerProvider(t, reg, "owned-lowtrust", model, 100)
	setProviderAccount(owned, "acct-A")
	lowerTrust(owned, TrustSelfSigned) // un-enrolled personal Mac

	req := &PendingRequest{
		RequestID:          "req-prefer-trust",
		Model:              model,
		RequestedMaxTokens: 128,
		PreferOwner:        true,
		OwnerAccountID:     "acct-A",
	}
	selected, _ := reg.ReserveProviderEx(model, req)
	if selected == nil || selected.ID != owned.ID {
		t.Fatalf("prefer must relax the trust floor for the caller's own machine; got %v", selected)
	}

	// A low-trust PUBLIC machine (different account) must NOT be relaxed.
	reg2 := New(testLogger())
	reg2.MinTrustLevel = TrustHardware
	pub := makeSchedulerProvider(t, reg2, "pub-lowtrust", model, 100)
	setProviderAccount(pub, "acct-B")
	lowerTrust(pub, TrustSelfSigned)
	req2 := &PendingRequest{RequestID: "r2", Model: model, RequestedMaxTokens: 128, PreferOwner: true, OwnerAccountID: "acct-A"}
	if selected, _ := reg2.ReserveProviderEx(model, req2); selected != nil {
		t.Fatalf("prefer must NOT relax trust for a non-owned public provider; got %q", selected.ID)
	}
}

// TestListModelsExcludesPrivateOnly verifies a private-only machine does not
// inflate the public /v1/models aggregation.
func TestListModelsExcludesPrivateOnly(t *testing.T) {
	reg := New(testLogger())
	model := "stats-model"

	pub := makeSchedulerProvider(t, reg, "pub", model, 100)
	setProviderAccount(pub, "acct-B")
	priv := makeSchedulerProvider(t, reg, "priv", model, 100)
	setProviderAccount(priv, "acct-A")
	setProviderPrivateOnly(priv)

	models := reg.ListModels()
	var found *AggregateModel
	for i := range models {
		if models[i].ID == model {
			found = &models[i]
		}
	}
	if found == nil {
		t.Fatal("public model missing from ListModels")
	}
	if found.Providers != 1 {
		t.Fatalf("ListModels Providers=%d, want 1 (private-only machine must be excluded)", found.Providers)
	}
}

func lowerTrust(p *Provider, level TrustLevel) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.TrustLevel = level
}
