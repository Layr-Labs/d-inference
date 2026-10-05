package registry_test

import (
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func setNativeMediaCapability(p *production.Provider, model string, enabled bool) {
	p.Mu().Lock()
	defer p.Mu().Unlock()
	p.ToolConstraintProtocol = production.ToolConstraintProtocolV1
	p.ToolConstraintModels = map[string]struct{}{model: {}}
	for i := range p.Models {
		if p.Models[i].ID == model {
			p.Models[i].IsVision = true
			p.Models[i].NativeMediaTools = enabled
		}
	}
}

func TestNativeMediaToolsRequireExplicitModelCapability(t *testing.T) {
	r := production.New(testLogger())
	model := "media-build"
	p := makeSchedulerProvider(t, r, "legacy", model, 100)
	setProviderVersion(p, "99.0.0")
	setNativeMediaCapability(p, model, false)
	ordinary := production.RequestTraits{HasTools: true, RequiresToolConstraint: true}
	native := ordinary
	native.RequiresNativeMediaTools = true
	if n, _, _ := r.QuickCapacityCheckForRequest(model, 10, 32, ordinary, true); n != 1 {
		t.Fatal("ordinary tools/media provider regressed")
	}
	if n, _, _ := r.QuickCapacityCheckForRequest(model, 10, 32, native, true); n != 0 {
		t.Fatal("legacy provider served native media tools")
	}
	setNativeMediaCapability(p, model, true)
	if n, _, _ := r.QuickCapacityCheckForRequest(model, 10, 32, native, true); n != 1 {
		t.Fatal("capable provider rejected")
	}
	if r.HasProviderAdvertisingNativeMediaTools("different-build") {
		t.Fatal("capability crossed model identity")
	}
	p.Mu().Lock()
	p.ToolConstraintProtocol = 0
	p.Mu().Unlock()
	if n, _, _ := r.QuickCapacityCheckForRequest(model, 10, 32, native, true); n != 0 {
		t.Fatal("media flag bypassed required tool protocol")
	}
	setNativeMediaCapability(p, model, true)
	p.Mu().Lock()
	p.Models[0].NativeMediaTools = false
	p.Mu().Unlock()
	if n, _, _ := r.QuickCapacityCheckForRequest(model, 10, 32, native, true); n != 0 {
		t.Fatal("revoked capability stayed routable")
	}
}

func TestNativeMediaToolsAliasSelectsCapableBuild(t *testing.T) {
	r := production.New(testLogger())
	old := makeSchedulerProvider(t, r, "old", "desired", 100)
	fresh := makeSchedulerProvider(t, r, "new", "previous", 100)
	setProviderVersion(old, "99.0.0")
	setProviderVersion(fresh, "99.0.0")
	setNativeMediaCapability(old, "desired", false)
	setNativeMediaCapability(fresh, "previous", true)
	r.SetModelAliases(map[string]production.AliasTarget{"public": {Desired: "desired", Previous: "previous"}})
	traits := production.RequestTraits{HasTools: true, RequiresToolConstraint: true, RequiresNativeMediaTools: true}
	model, alias, ok := r.ResolveModelConstrainedWithTraits("public", nil, "", false, false, traits)
	if !ok || !alias || model != "previous" {
		t.Fatalf("unsafe alias selection: %s %t %t", model, alias, ok)
	}
	traits.RequiresNativeMediaTools = false
	model, _, ok = r.ResolveModelConstrainedWithTraits("public", nil, "", false, false, traits)
	if !ok || model != "desired" {
		t.Fatal("ordinary constrained alias behavior changed")
	}
}

func TestNativeMediaToolsQueuedNoneCannotDowngradeAfterRevocation(t *testing.T) {
	r := production.New(testLogger())
	model := "queued-media"
	p := makeSchedulerProvider(t, r, "provider", model, 100)
	setProviderVersion(p, "99.0.0")
	setNativeMediaCapability(p, model, false)
	q := &production.QueuedRequest{RequestID: "native-media", Model: model, ResponseCh: make(chan *production.Provider, 1), Pending: &production.PendingRequest{
		RequestID: "native-media", Model: model, EstimatedPromptTokens: 10, RequestedMaxTokens: 32, RequiresVision: true,
		Traits: production.RequestTraits{RequiresNativeMediaTools: true, ToolChoiceMode: "none"}}}
	if err := r.Queue().Enqueue(q); err != nil {
		t.Fatal(err)
	}
	r.DrainQueuedRequestsForModel(model)
	select {
	case selected := <-q.ResponseCh:
		if selected != nil || !errors.Is(q.FailureReason, production.ErrQueueToolConstraintUnavailable) {
			t.Fatalf("queued media silently downgraded: %v %v", selected, q.FailureReason)
		}
	case <-time.After(time.Second):
		t.Fatal("unsupported queued media did not terminate")
	}
}

func TestNativeMediaToolsModelsUpdateAndFinalReservation(t *testing.T) {
	r := production.New(testLogger())
	const model = "native-update"
	p := makeSchedulerProvider(t, r, "provider", model, 100)
	setProviderVersion(p, "99.0.0")
	traits := production.RequestTraits{RequiresNativeMediaTools: true, ToolChoiceMode: "none"}
	for _, enabled := range []bool{true, false, true} {
		r.MergeProviderModelsWithCapabilities(p.ID,
			[]protocol.ModelInfo{{ID: model, IsVision: true, NativeMediaTools: enabled}},
			production.ToolConstraintProtocolV1, []string{model})
		if got := r.HasProviderAdvertisingNativeMediaTools(model); got != enabled {
			t.Fatalf("models_update capability: got %v, want %v", got, enabled)
		}
		pending := &production.PendingRequest{RequestID: "reserve-media", Model: model,
			EstimatedPromptTokens: 10, RequestedMaxTokens: 32, RequiresVision: true, Traits: traits}
		selected, _ := r.ReserveProviderEx(model, pending)
		if (selected != nil) != enabled {
			t.Fatalf("final reservation ignored latest capability: enabled=%v selected=%v", enabled, selected != nil)
		}
		if selected != nil {
			selected.RemovePending(pending.RequestID)
			r.SetProviderIdle(selected.ID)
		}
	}
	r.Disconnect(p.ID)
	if r.HasProviderAdvertisingNativeMediaTools(model) || r.HasNativeMediaToolProviderForRouting(model, "", false, false) {
		t.Fatal("disconnect retained native media capability")
	}
}

func TestNativeMediaToolsOwnerAndExclusionRemainBinding(t *testing.T) {
	r := production.New(testLogger())
	model := "owner-media"
	p := makeSchedulerProvider(t, r, "public", model, 100)
	setProviderVersion(p, "99.0.0")
	setNativeMediaCapability(p, model, true)
	p.Mu().Lock()
	p.AccountID = "other"
	p.Mu().Unlock()
	if r.HasNativeMediaToolProviderForRouting(model, "owner", true, false) {
		t.Fatal("public provider satisfied owned-only capability")
	}
	if !r.HasNativeMediaToolProviderForRouting(model, "owner", false, true) {
		t.Fatal("prefer owner lost capable public fallback")
	}
	pending := &production.PendingRequest{OwnerAccountID: "owner", PreferOwner: true, ExcludedProviderIDs: []string{p.ID}, Traits: production.RequestTraits{RequiresNativeMediaTools: true}}
	q := &production.QueuedRequest{RequestID: "excluded-media", Model: model, Pending: pending, ResponseCh: make(chan *production.Provider, 1)}
	if err := r.Queue().Enqueue(q); err != nil {
		t.Fatal(err)
	}
	// The synchronous drain invokes the pending-request capability check after
	// reservation rejects the excluded provider, and must fail rather than requeue.
	r.DrainQueuedRequestsForModel(model)
	select {
	case selected := <-q.ResponseCh:
		if selected != nil || !errors.Is(q.FailureReason, production.ErrQueueToolConstraintUnavailable) {
			t.Fatal("excluded provider satisfied retry capability")
		}
	default:
		t.Fatal("excluded provider kept retry queued")
	}
}
