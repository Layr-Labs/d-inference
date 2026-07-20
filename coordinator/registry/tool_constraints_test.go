package registry

import (
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestToolConstraintRoutingRequiresExplicitConcreteModel(t *testing.T) {
	reg := New(testLogger())
	model := "gemma-4-build"
	provider := makeSchedulerProvider(t, reg, "provider", model, 100)
	setProviderVersion(provider, "99.0.0")
	provider.mu.Lock()
	provider.ToolConstraintProtocol = ToolConstraintProtocolV1
	provider.mu.Unlock()

	if candidates, _, _ := reg.QuickCapacityCheck(
		model, 10, 32, RequestTraits{HasTools: true},
	); candidates != 1 {
		t.Fatalf("ordinary auto tool request lost current provider: %d", candidates)
	}
	if candidates, _, _ := reg.QuickCapacityCheck(
		model, 10, 32,
		RequestTraits{HasTools: true, RequiresToolConstraint: true},
	); candidates != 0 {
		t.Fatalf("protocol-only provider served constrained request: %d", candidates)
	}

	provider.mu.Lock()
	provider.ToolConstraintModels = map[string]struct{}{model: {}}
	provider.mu.Unlock()
	if candidates, _, _ := reg.QuickCapacityCheck(
		model, 10, 32,
		RequestTraits{HasTools: true, RequiresToolConstraint: true},
	); candidates != 1 {
		t.Fatalf("explicit constrained model was not routable: %d", candidates)
	}

	provider.mu.Lock()
	provider.ToolConstraintProtocol = 0
	provider.mu.Unlock()
	if candidates, _, _ := reg.QuickCapacityCheck(
		model, 10, 32,
		RequestTraits{HasTools: true, RequiresToolConstraint: true},
	); candidates != 0 {
		t.Fatalf("old provider silently downgraded constrained request: %d", candidates)
	}
	if candidates, _, _ := reg.QuickCapacityCheck(
		model, 10, 32, RequestTraits{HasTools: true},
	); candidates != 1 {
		t.Fatalf("old provider stopped serving auto tool requests: %d", candidates)
	}
}

func TestToolConstraintModelAdvertisementDropsUnknownModels(t *testing.T) {
	models := []protocol.ModelInfo{{ID: "known"}}
	got := toolConstraintModelSet(
		[]string{"unknown", "known", "known"}, models)
	if len(got) != 1 {
		t.Fatalf("validated model set = %#v", got)
	}
	if _, ok := got["known"]; !ok {
		t.Fatalf("known model missing: %#v", got)
	}
}

func TestQueuedConstraintTerminatesWhenOnlyOldProvidersRemain(t *testing.T) {
	reg := New(testLogger())
	model := "gemma-4-queue"
	old := makeSchedulerProvider(t, reg, "old", model, 100)
	setProviderVersion(old, "0.7.10")
	request := &QueuedRequest{
		RequestID:  "queued-constraint",
		Model:      model,
		ResponseCh: make(chan *Provider, 1),
		Pending: &PendingRequest{
			RequestID:          "queued-constraint",
			Model:              model,
			RequestedMaxTokens: 32,
			Traits: RequestTraits{
				HasTools:               true,
				RequiresToolConstraint: true,
			},
		},
	}
	if err := reg.Queue().Enqueue(request); err != nil {
		t.Fatal(err)
	}
	reg.DrainQueuedRequestsForModel(model)
	select {
	case provider := <-request.ResponseCh:
		if provider != nil {
			t.Fatalf("old provider received constrained request: %s", provider.ID)
		}
		if !errors.Is(
			request.FailureReason, ErrQueueToolConstraintUnavailable,
		) {
			t.Fatalf("failure = %v", request.FailureReason)
		}
	case <-time.After(time.Second):
		t.Fatal("constrained request waited instead of terminating")
	}
}

func TestQueuedSelfRouteConstraintIgnoresUnrelatedCapableProviders(t *testing.T) {
	reg := New(testLogger())
	model := "gemma-4-self-route-queue"
	owner := makeSchedulerProvider(t, reg, "owner-old", model, 100)
	setProviderVersion(owner, "0.7.10")
	owner.mu.Lock()
	owner.AccountID = "owner"
	owner.mu.Unlock()

	public := makeSchedulerProvider(t, reg, "public-capable", model, 100)
	setProviderVersion(public, "99.0.0")
	public.mu.Lock()
	public.AccountID = "other"
	public.ToolConstraintProtocol = ToolConstraintProtocolV1
	public.ToolConstraintModels = map[string]struct{}{model: {}}
	public.mu.Unlock()

	request := &QueuedRequest{
		RequestID:  "queued-self-route-constraint",
		Model:      model,
		ResponseCh: make(chan *Provider, 1),
		Pending: &PendingRequest{
			RequestID:          "queued-self-route-constraint",
			Model:              model,
			RequestedMaxTokens: 32,
			OwnerAccountID:     "owner",
			SelfRouteOnly:      true,
			Traits: RequestTraits{
				HasTools:               true,
				RequiresToolConstraint: true,
			},
		},
	}
	if err := reg.Queue().Enqueue(request); err != nil {
		t.Fatal(err)
	}
	reg.DrainQueuedRequestsForModel(model)
	select {
	case selected := <-request.ResponseCh:
		if selected != nil {
			t.Fatalf("unrelated provider received self-route request: %s", selected.ID)
		}
		if !errors.Is(request.FailureReason, ErrQueueToolConstraintUnavailable) {
			t.Fatalf("failure = %v", request.FailureReason)
		}
	case <-time.After(time.Second):
		t.Fatal("self-route request waited on an unrelated capable provider")
	}
}

func TestQueuedConstraintTerminatesWhenLastCapableProviderDisconnects(t *testing.T) {
	reg := New(testLogger())
	model := "gemma-4-disconnect"
	provider := makeSchedulerProvider(t, reg, "capable", model, 100)
	provider.mu.Lock()
	provider.ToolConstraintProtocol = ToolConstraintProtocolV1
	provider.ToolConstraintModels = map[string]struct{}{model: {}}
	provider.mu.Unlock()

	request := &QueuedRequest{
		RequestID:  "queued-disconnect",
		Model:      model,
		ResponseCh: make(chan *Provider, 1),
		Pending: &PendingRequest{
			RequestID:          "queued-disconnect",
			Model:              model,
			RequestedMaxTokens: 32,
			Traits: RequestTraits{
				HasTools:               true,
				RequiresToolConstraint: true,
			},
		},
	}
	if err := reg.Queue().Enqueue(request); err != nil {
		t.Fatal(err)
	}

	reg.Disconnect(provider.ID)

	select {
	case selected := <-request.ResponseCh:
		if selected != nil {
			t.Fatalf("disconnected provider received constrained request: %s", selected.ID)
		}
		if !errors.Is(request.FailureReason, ErrQueueToolConstraintUnavailable) {
			t.Fatalf("failure = %v", request.FailureReason)
		}
	case <-time.After(time.Second):
		t.Fatal("disconnect left constrained request waiting for queue timeout")
	}
}

func TestModelsUpdateRefreshesConstraintRoutingImmediately(t *testing.T) {
	reg := New(testLogger())
	oldModel := "gemma-4-old"
	newModel := "gemma-4-hot"
	provider := makeSchedulerProvider(t, reg, "provider", oldModel, 100)
	setProviderVersion(provider, "99.0.0")
	provider.mu.Lock()
	provider.AccountID = "owner"
	provider.ToolConstraintProtocol = ToolConstraintProtocolV1
	provider.ToolConstraintModels = map[string]struct{}{oldModel: {}}
	provider.mu.Unlock()

	merged, _ := reg.MergeProviderModelsWithCapabilities(
		provider.ID,
		[]protocol.ModelInfo{{ID: newModel, ModelType: "gemma4_text"}},
		ToolConstraintProtocolV1,
		[]string{newModel},
	)
	if len(merged) != 1 || merged[0] != newModel {
		t.Fatalf("hot model merge = %#v", merged)
	}
	traits := RequestTraits{
		HasTools: true, RequiresToolConstraint: true,
	}
	if candidates, _, _ := reg.QuickCapacityCheck(
		newModel, 10, 32, traits,
	); candidates != 1 {
		t.Fatalf("public constrained hot model candidates = %d", candidates)
	}
	_, owned := reg.OwnedProviderSummary(
		"owner", newModel, traits, false)
	if owned != 1 {
		t.Fatalf("self-route constrained hot model providers = %d", owned)
	}
	pending := &PendingRequest{
		RequestID:          "prefer-hot",
		Model:              newModel,
		RequestedMaxTokens: 32,
		OwnerAccountID:     "owner",
		PreferOwner:        true,
		Traits:             traits,
	}
	selected, _ := reg.ReserveProviderEx(newModel, pending)
	if selected == nil || selected.ID != provider.ID {
		t.Fatal("prefer route did not select hot-updated capable provider")
	}
	selected.RemovePending(pending.RequestID)
	reg.SetProviderIdle(selected.ID)

	reg.MergeProviderModelsWithCapabilities(
		provider.ID,
		[]protocol.ModelInfo{{ID: newModel, ModelType: "qwen"}},
		ToolConstraintProtocolV1,
		[]string{},
	)
	if candidates, _, _ := reg.QuickCapacityCheck(
		newModel, 10, 32, traits,
	); candidates != 0 {
		t.Fatalf("removed hot capability still routed: %d", candidates)
	}
}

func TestAliasResolutionFallsBackToConstraintCapablePreviousBuild(t *testing.T) {
	reg := New(testLogger())
	desired := "gemma-4-desired"
	previous := "gemma-4-previous"
	desiredProvider := makeSchedulerProvider(t, reg, "desired-old", desired, 100)
	previousProvider := makeSchedulerProvider(t, reg, "previous-capable", previous, 100)
	setProviderVersion(desiredProvider, "0.7.10")
	setProviderVersion(previousProvider, "99.0.0")
	previousProvider.mu.Lock()
	previousProvider.ToolConstraintProtocol = ToolConstraintProtocolV1
	previousProvider.ToolConstraintModels = map[string]struct{}{previous: {}}
	previousProvider.mu.Unlock()
	reg.SetModelAliases(map[string]AliasTarget{
		"gemma-4": {Desired: desired, Previous: previous},
	})

	build, isAlias, ok := reg.ResolveModelConstrainedWithTraits(
		"gemma-4", nil, "", false, false,
		RequestTraits{HasTools: true, RequiresToolConstraint: true})
	if !ok || !isAlias || build != previous {
		t.Fatalf(
			"constrained alias resolved to build=%q alias=%v ok=%v, want previous %q",
			build, isAlias, ok, previous)
	}

	build, _, ok = reg.ResolveModelConstrainedWithTraits(
		"gemma-4", nil, "", false, false, RequestTraits{})
	if !ok || build != desired {
		t.Fatalf("ordinary alias resolved to %q ok=%v, want desired %q", build, ok, desired)
	}
}
