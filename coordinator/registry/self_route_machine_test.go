package registry

import "testing"

func TestSelfRouteMachineReservationAndPlan(t *testing.T) {
	reg := New(testLogger())
	const model = "machine-model"
	selected := makeSchedulerProvider(t, reg, "selected", model, 100)
	other := makeSchedulerProvider(t, reg, "other", model, 500)
	setProviderAccount(selected, "owner")
	setProviderAccount(other, "owner")
	request := &PendingRequest{RequestID: "pinned", Model: model, EstimatedPromptTokens: 32, RequestedMaxTokens: 64, OwnerAccountID: "owner", SelfRouteOnly: true, Traits: RequestTraits{TargetProviderID: "selected"}}
	provider, _, plan := reg.ReserveProviderWithPlan(model, request)
	if provider == nil || provider.ID != "selected" {
		t.Fatalf("reserved=%v, want selected machine", provider)
	}
	// A retry excluding the selected session cannot spill to another owned box,
	// whether it uses the retained plan or performs a fresh scheduler scan.
	request.ExcludedProviderIDs = []string{"selected"}
	if provider, _, _ := reg.ReserveNextFromPlan(request, plan); provider != nil {
		t.Fatalf("plan spilled to %s", provider.ID)
	}
	if provider, _ := reg.ReserveProviderEx(model, request); provider != nil {
		t.Fatalf("scan spilled to %s", provider.ID)
	}
	// The same target still cannot cross the owner boundary.
	request.OwnerAccountID = "foreign"
	request.ExcludedProviderIDs = nil
	if provider, _ := reg.ReserveProviderEx(model, request); provider != nil {
		t.Fatalf("foreign owner reserved %s", provider.ID)
	}
}

func TestSelfRouteMachineSummary(t *testing.T) {
	reg := New(testLogger())
	selected := makeSchedulerProvider(t, reg, "selected", "selected-model", 100)
	other := makeSchedulerProvider(t, reg, "other", "other-model", 100)
	setProviderAccount(selected, "owner")
	setProviderAccount(other, "owner")
	traits := RequestTraits{TargetProviderID: "selected"}
	if online, serves := reg.OwnedProviderSummary("owner", "other-model", traits, false); online != 1 || serves != 0 {
		t.Fatalf("summary=(%d,%d), want (1,0)", online, serves)
	}
	selected.mu.Lock()
	selected.Status = StatusOffline
	selected.mu.Unlock()
	if online, serves := reg.OwnedProviderSummary("owner", "selected-model", traits, false); online != 0 || serves != 0 {
		t.Fatalf("offline summary=(%d,%d), want (0,0)", online, serves)
	}
}

func TestSelfRouteMachineAliasResolution(t *testing.T) {
	reg := New(testLogger())
	selected := registerProviderWithModel(reg, "selected", aliasFP8)
	other := registerProviderWithModel(reg, "other", aliasQAT)
	makeProviderRoutable(selected)
	makeProviderRoutable(other)
	setProviderAccount(selected, "owner")
	setProviderAccount(other, "owner")
	reg.SetModelAliases(map[string]AliasTarget{"gemma-4-26b": {Desired: aliasQAT, Previous: aliasFP8}})
	traits := RequestTraits{TargetProviderID: "selected"}
	build, isAlias, ok := reg.ResolveModelConstrainedWithTraits("gemma-4-26b", nil, "owner", true, false, traits)
	if !ok || !isAlias || build != aliasFP8 {
		t.Fatalf("resolved=(%q,%v,%v), want selected machine's previous build", build, isAlias, ok)
	}
	traits.TargetProviderID = "missing"
	if build, _, ok := reg.ResolveModelConstrainedWithTraits("gemma-4-26b", nil, "owner", true, false, traits); ok {
		t.Fatalf("missing target resolved to %q", build)
	}
}
