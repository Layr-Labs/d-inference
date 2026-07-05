package registry

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
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

	online, serves := reg.OwnedProviderSummary("acct-A", model, RequestTraits{}, false)
	if online != 1 {
		t.Fatalf("acct-A online=%d, want 1 (a1 online, a2 offline)", online)
	}
	if serves != 1 {
		t.Fatalf("acct-A servesModel=%d, want 1", serves)
	}

	// Unknown model: online still counts, servesModel drops to 0.
	online, serves = reg.OwnedProviderSummary("acct-A", "model-not-served", RequestTraits{}, false)
	if online != 1 {
		t.Fatalf("acct-A online=%d for unknown model, want 1", online)
	}
	if serves != 0 {
		t.Fatalf("acct-A servesModel=%d for unknown model, want 0", serves)
	}

	// An account with no providers gets zeros.
	if online, serves = reg.OwnedProviderSummary("acct-none", model, RequestTraits{}, false); online != 0 || serves != 0 {
		t.Fatalf("acct-none summary=(%d,%d), want (0,0)", online, serves)
	}

	// Empty account never matches.
	if online, serves = reg.OwnedProviderSummary("", model, RequestTraits{}, false); online != 0 || serves != 0 {
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

// TestSelfRouteVisionRoutesToOwnedOffCatalogVLM verifies that a self-route
// media request reaches the owner's off-catalog VLM: the owner context that
// admits an off-catalog model past the routable gate must also carry through
// the vision gate, or the model would be listed/accepted but never selectable
// for image/video input. The same off-catalog VLM stays invisible to public
// media requests.
func TestSelfRouteVisionRoutesToOwnedOffCatalogVLM(t *testing.T) {
	reg := New(testLogger())
	model := "local/off-catalog-vlm"

	mine := makeSchedulerProvider(t, reg, "mine", model, 100)
	mine.mu.Lock()
	mine.Models = []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit", IsVision: true}}
	mine.mu.Unlock()
	setProviderAccount(mine, "acct-A")
	reg.SetModelCatalog([]CatalogEntry{{ID: "catalog-only-model"}})

	owner := &PendingRequest{
		RequestID:          "req-vlm",
		Model:              model,
		RequestedMaxTokens: 128,
		SelfRouteOnly:      true,
		OwnerAccountID:     "acct-A",
		RequiresVision:     true,
	}
	selected, decision := reg.ReserveProviderEx(model, owner)
	if selected == nil {
		t.Fatalf("owner media request failed to reach their off-catalog VLM; decision=%+v", decision)
	}
	if selected.ID != mine.ID {
		t.Fatalf("selected %q, want %q", selected.ID, mine.ID)
	}

	// Contrast: a public media request must not route to the off-catalog model.
	public := &PendingRequest{RequestID: "req-pub", Model: model, RequestedMaxTokens: 128, RequiresVision: true}
	if selected := reg.ReserveProvider(model, public); selected != nil {
		t.Fatalf("public media request reached off-catalog model on %q", selected.ID)
	}

	// A text-only off-catalog build must still be rejected for media, even for
	// its owner — the owner context relaxes the catalog filter, not the
	// vision-capability requirement.
	mine.mu.Lock()
	mine.Models = []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit", IsVision: false}}
	mine.mu.Unlock()
	if selected, _ := reg.ReserveProviderEx(model, owner); selected != nil {
		t.Fatalf("owner media request reached a text-only build on %q", selected.ID)
	}
}

// TestSelfRouteOffCatalogFitGateUsesAdvertisedSize verifies that the
// hardware-fit gate does not fail open for an off-catalog model: with no
// catalog sizing, the provider-advertised SizeBytes must be used, so a local
// model that can never fit the machine is rejected deterministically as
// model-too-large instead of dispatching into a provider-side load failure.
func TestSelfRouteOffCatalogFitGateUsesAdvertisedSize(t *testing.T) {
	reg := New(testLogger())
	model := "local/off-catalog-huge"

	mine := makeSchedulerProvider(t, reg, "mine", model, 100)
	mine.mu.Lock()
	// 200 GB advertised weights on a 64 GB machine, and the model is NOT
	// resident (slot unknown) so the cold-load fit gate applies.
	mine.Models = []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit", SizeBytes: 200_000_000_000}}
	mine.BackendCapacity.Slots[0].State = "unknown"
	mine.mu.Unlock()
	setProviderAccount(mine, "acct-A")
	reg.SetModelCatalog([]CatalogEntry{{ID: "catalog-only-model"}})

	owner := &PendingRequest{
		RequestID:          "req-huge",
		Model:              model,
		RequestedMaxTokens: 128,
		SelfRouteOnly:      true,
		OwnerAccountID:     "acct-A",
	}
	selected, decision := reg.ReserveProviderEx(model, owner)
	if selected != nil {
		t.Fatalf("selected %q for a 200GB model on a 64GB machine; fit gate failed open", selected.ID)
	}
	if decision.ModelTooLargeRejections != 1 {
		t.Fatalf("ModelTooLargeRejections=%d, want 1; decision=%+v", decision.ModelTooLargeRejections, decision)
	}

	// A right-sized off-catalog model on the same machine routes fine.
	mine.mu.Lock()
	mine.Models = []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit", SizeBytes: 5_000_000_000}}
	mine.mu.Unlock()
	if selected, decision := reg.ReserveProviderEx(model, owner); selected == nil {
		t.Fatalf("right-sized off-catalog model failed to route; decision=%+v", decision)
	}
}

// TestSelfRouteCatalogModelKeepsWeightHashGate verifies that the owner
// self-route exemption widens WHICH models are reachable (off-catalog local
// models) without lifting the weight-hash tamper tripwire on builds the
// catalog DOES track: an owned box advertising a catalog model with a
// mismatched weight hash stays unroutable even for its owner.
func TestSelfRouteCatalogModelKeepsWeightHashGate(t *testing.T) {
	reg := New(testLogger())
	model := "catalog-model"

	mine := makeSchedulerProvider(t, reg, "mine", model, 100)
	setProviderAccount(mine, "acct-A")
	reg.SetModelCatalog([]CatalogEntry{{ID: model, WeightHash: "expected-hash"}})

	owner := &PendingRequest{
		RequestID:          "req-hash",
		Model:              model,
		RequestedMaxTokens: 128,
		SelfRouteOnly:      true,
		OwnerAccountID:     "acct-A",
	}

	// Advertised hash disagrees with the catalog: blocked, owner or not.
	mine.mu.Lock()
	mine.Models = []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit", WeightHash: "tampered-hash"}}
	mine.mu.Unlock()
	if selected, _ := reg.ReserveProviderEx(model, owner); selected != nil {
		t.Fatalf("owner self-route reached a catalog model with mismatched weight hash on %q", selected.ID)
	}
	// List/route agreement: the unroutable stale-hash build must not be
	// advertised by OwnedModels either (a listed model every request then
	// fails to dispatch is worse than an absent one).
	if listed := reg.OwnedModels("acct-A"); len(listed) != 0 {
		t.Fatalf("OwnedModels advertises unroutable stale-hash build: %+v", listed)
	}

	// Matching hash routes.
	mine.mu.Lock()
	mine.Models = []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit", WeightHash: "expected-hash"}}
	mine.mu.Unlock()
	if selected, decision := reg.ReserveProviderEx(model, owner); selected == nil {
		t.Fatalf("hash-matching catalog model failed to self-route; decision=%+v", decision)
	}
	if listed := reg.OwnedModels("acct-A"); len(listed) != 1 || listed[0].ID != model {
		t.Fatalf("OwnedModels = %+v, want the hash-matching catalog build %q", listed, model)
	}

	// A provider that omits the hash entirely is admitted (grading happens at
	// registration; an absent hash is not a mismatch) — unchanged semantics of
	// modelAllowedByCatalogLocked.
	mine.mu.Lock()
	mine.Models = []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}
	mine.mu.Unlock()
	if selected, decision := reg.ReserveProviderEx(model, owner); selected == nil {
		t.Fatalf("hash-less catalog model failed to self-route; decision=%+v", decision)
	}
}

// TestOwnedProviderSummaryAppliesTraitAndVisionGates verifies the owner
// preflight matches the dispatch-time gates for the REQUEST's shape: a tool
// call to an owned box below the tools capability floor, or a media request to
// a text-only build, must report servesModel=0 (fast 503 with the real cause)
// instead of passing preflight, queueing 120s, and dying as machine_busy.
func TestOwnedProviderSummaryAppliesTraitAndVisionGates(t *testing.T) {
	reg := New(testLogger())
	model := "traits-summary-model"

	mine := makeSchedulerProvider(t, reg, "mine", model, 100)
	setProviderAccount(mine, "acct-A")

	// Below the tools version floor (0.6.3): plain requests serve, tool
	// requests don't.
	mine.mu.Lock()
	mine.Version = "0.6.0"
	mine.mu.Unlock()
	if _, serves := reg.OwnedProviderSummary("acct-A", model, RequestTraits{}, false); serves != 1 {
		t.Fatalf("plain request servesModel=%d, want 1", serves)
	}
	if _, serves := reg.OwnedProviderSummary("acct-A", model, RequestTraits{HasTools: true}, false); serves != 0 {
		t.Fatalf("tools request to below-floor box servesModel=%d, want 0", serves)
	}

	// At/above the floor, tool requests serve again.
	mine.mu.Lock()
	mine.Version = "0.6.3"
	mine.mu.Unlock()
	if _, serves := reg.OwnedProviderSummary("acct-A", model, RequestTraits{HasTools: true}, false); serves != 1 {
		t.Fatalf("tools request to at-floor box servesModel=%d, want 0 — floor gate stuck", serves)
	}

	// Media requires a vision-capable build; a text-only advertisement fails
	// the vision leg, a VLM build passes it (owner context: off-catalog OK).
	if _, serves := reg.OwnedProviderSummary("acct-A", model, RequestTraits{}, true); serves != 0 {
		t.Fatalf("media request to text-only build servesModel=%d, want 0", serves)
	}
	mine.mu.Lock()
	mine.Models = []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit", IsVision: true}}
	mine.mu.Unlock()
	if _, serves := reg.OwnedProviderSummary("acct-A", model, RequestTraits{}, true); serves != 1 {
		t.Fatalf("media request to VLM build servesModel=%d, want 1", serves)
	}
}

// TestOwnedModelsExcludesRenderBrokenBuilds: list/route agreement for the
// template-render gate — an advertised build with an explicit
// template_render_ok=false is fenced at dispatch for every request shape, so
// OwnedModels (which feeds /v1/models and the key picker) must not list it.
// A nil tri-state (pre-0.6.5 provider, no opinion) stays listed.
func TestOwnedModelsExcludesRenderBrokenBuilds(t *testing.T) {
	reg := New(testLogger())
	model := "render-broken-model"

	mine := makeSchedulerProvider(t, reg, "mine", model, 100)
	setProviderAccount(mine, "acct-A")

	broken := false
	mine.mu.Lock()
	mine.Models = []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit", TemplateRenderOK: &broken}}
	mine.mu.Unlock()
	if listed := reg.OwnedModels("acct-A"); len(listed) != 0 {
		t.Fatalf("OwnedModels lists render-broken build: %+v", listed)
	}
	// And the preflight agrees (base traits fence render-broken everywhere).
	if _, serves := reg.OwnedProviderSummary("acct-A", model, RequestTraits{}, false); serves != 0 {
		t.Fatalf("preflight admits render-broken build: servesModel=%d", serves)
	}

	ok := true
	mine.mu.Lock()
	mine.Models = []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit", TemplateRenderOK: &ok}}
	mine.mu.Unlock()
	if listed := reg.OwnedModels("acct-A"); len(listed) != 1 || listed[0].ID != model {
		t.Fatalf("OwnedModels = %+v, want the render-OK build", listed)
	}

	mine.mu.Lock()
	mine.Models = []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}} // nil tri-state
	mine.mu.Unlock()
	if listed := reg.OwnedModels("acct-A"); len(listed) != 1 {
		t.Fatalf("OwnedModels = %+v, want the no-opinion build listed", listed)
	}
}
