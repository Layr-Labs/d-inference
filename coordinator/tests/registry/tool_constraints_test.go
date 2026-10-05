package registry_test

import (
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestToolConstraintModelAdvertisementDropsUnknownModels(t *testing.T) {
	reg := production.New(testLogger())
	msg := testRegisterMessage()
	msg.Models = []protocol.ModelInfo{{ID: "known"}}
	msg.ToolConstraintModels = []string{"unknown", "known", "known"}
	provider := reg.Register("p", nil, msg)
	provider.Mu().Lock()
	defer provider.Mu().Unlock()
	got := provider.ToolConstraintModels
	if len(got) != 1 {
		t.Fatalf("validated model set = %#v", got)
	}
	if _, ok := got["known"]; !ok {
		t.Fatalf("known model missing: %#v", got)
	}
}

func TestConstraintAvailabilityPreservesResidentHardwareFitBypass(t *testing.T) {
	reg := production.New(testLogger())
	model := "gemma-4-resident-oversized"
	reg.SetModelCatalog([]production.CatalogEntry{{
		ID: model, SizeGB: 100, MinRAMGB: 128,
	}})
	msg := testRegisterMessage()
	msg.Models = []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}
	msg.DecodeTPS = 100
	msg.ToolConstraintProtocol = production.ToolConstraintProtocolV1
	msg.ToolConstraintModels = []string{model}
	provider := reg.Register("resident-capable", nil, msg)
	provider.SetVersion("99.0.0")
	makeProviderRoutable(provider)
	provider.Mu().Lock()
	provider.SystemMetrics = protocol.SystemMetrics{MemoryPressure: 0.1, CPUUsage: 0.1, ThermalState: "nominal"}
	provider.BackendCapacity = &protocol.BackendCapacity{
		TotalMemoryGB: 64,
		Slots:         []protocol.BackendSlotCapacity{{Model: model, State: "running"}},
	}
	provider.Mu().Unlock()

	pending := &production.PendingRequest{
		Model: model,
		Traits: production.RequestTraits{
			HasTools: true, RequiresToolConstraint: true,
		},
	}
	if !reg.HasToolConstraintProviderForRouting(model, pending.OwnerAccountID,
		pending.SelfRouteOnly, pending.PreferOwner, pending.AllowedProviderSerials...) {
		t.Fatal("resident capable provider was rejected by cold hardware heuristic")
	}
}

func TestConstraintAvailabilityUsesOwnerOffCatalogModelSize(t *testing.T) {
	reg := production.New(testLogger())
	model := "owner-local-oversized"
	reg.SetModelCatalog([]production.CatalogEntry{{ID: "unrelated-catalog-build"}})
	msg := testRegisterMessage()
	msg.Models = []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit", SizeBytes: 100 << 30}}
	msg.DecodeTPS = 100
	msg.ToolConstraintProtocol = production.ToolConstraintProtocolV1
	msg.ToolConstraintModels = []string{model}
	provider := reg.Register("owner-local", nil, msg)
	provider.SetVersion("99.0.0")
	makeProviderRoutable(provider)
	provider.Mu().Lock()
	provider.AccountID = "owner"
	provider.PrivateOnly = true
	provider.SystemMetrics = protocol.SystemMetrics{MemoryPressure: 0.1, CPUUsage: 0.1, ThermalState: "nominal"}
	provider.BackendCapacity = &protocol.BackendCapacity{
		TotalMemoryGB: 64,
		Slots:         []protocol.BackendSlotCapacity{{Model: model, State: "idle_shutdown"}},
	}
	provider.Mu().Unlock()

	pending := &production.PendingRequest{
		Model:          model,
		OwnerAccountID: "owner",
		SelfRouteOnly:  true,
		Traits: production.RequestTraits{
			HasTools: true, RequiresToolConstraint: true,
		},
	}
	if reg.HasToolConstraintProviderForRouting(model, pending.OwnerAccountID,
		pending.SelfRouteOnly, pending.PreferOwner, pending.AllowedProviderSerials...) {
		t.Fatal("oversized owner-local model bypassed advertised-size hardware fit")
	}
}

func TestToolConstraintRoutingRequiresExplicitConcreteModel(t *testing.T) {
	reg := production.New(testLogger())
	model := "gemma-4-build"
	provider := makeSchedulerProvider(t, reg, "provider", model, 100)
	setProviderVersion(provider, "99.0.0")
	provider.Mu().Lock()
	provider.ToolConstraintProtocol = production.ToolConstraintProtocolV1
	provider.Mu().Unlock()

	if candidates, _, _ := reg.QuickCapacityCheck(
		model, 10, 32, production.RequestTraits{HasTools: true},
	); candidates != 1 {
		t.Fatalf("ordinary auto tool request lost current provider: %d", candidates)
	}
	if candidates, _, _ := reg.QuickCapacityCheck(
		model, 10, 32,
		production.RequestTraits{HasTools: true, RequiresToolConstraint: true},
	); candidates != 0 {
		t.Fatalf("protocol-only provider served constrained request: %d", candidates)
	}

	provider.Mu().Lock()
	provider.ToolConstraintModels = map[string]struct{}{model: {}}
	provider.Mu().Unlock()
	if candidates, _, _ := reg.QuickCapacityCheck(
		model, 10, 32,
		production.RequestTraits{HasTools: true, RequiresToolConstraint: true},
	); candidates != 1 {
		t.Fatalf("explicit constrained model was not routable: %d", candidates)
	}

	provider.Mu().Lock()
	provider.ToolConstraintProtocol = 0
	provider.Mu().Unlock()
	if candidates, _, _ := reg.QuickCapacityCheck(
		model, 10, 32,
		production.RequestTraits{HasTools: true, RequiresToolConstraint: true},
	); candidates != 0 {
		t.Fatalf("old provider silently downgraded constrained request: %d", candidates)
	}
	if candidates, _, _ := reg.QuickCapacityCheck(
		model, 10, 32, production.RequestTraits{HasTools: true},
	); candidates != 1 {
		t.Fatalf("old provider stopped serving auto tool requests: %d", candidates)
	}
}

func TestQueuedConstraintTerminatesWhenOnlyOldProvidersRemain(t *testing.T) {
	reg := production.New(testLogger())
	model := "gemma-4-queue"
	old := makeSchedulerProvider(t, reg, "old", model, 100)
	setProviderVersion(old, "0.7.10")
	request := &production.QueuedRequest{
		RequestID:  "queued-constraint",
		Model:      model,
		ResponseCh: make(chan *production.Provider, 1),
		Pending: &production.PendingRequest{
			RequestID:          "queued-constraint",
			Model:              model,
			RequestedMaxTokens: 32,
			Traits: production.RequestTraits{
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
			request.FailureReason, production.ErrQueueToolConstraintUnavailable,
		) {
			t.Fatalf("failure = %v", request.FailureReason)
		}
	case <-time.After(time.Second):
		t.Fatal("constrained request waited instead of terminating")
	}
}

func TestQueuedSelfRouteConstraintIgnoresUnrelatedCapableProviders(t *testing.T) {
	reg := production.New(testLogger())
	model := "gemma-4-self-route-queue"
	owner := makeSchedulerProvider(t, reg, "owner-old", model, 100)
	setProviderVersion(owner, "0.7.10")
	owner.Mu().Lock()
	owner.AccountID = "owner"
	owner.Mu().Unlock()

	public := makeSchedulerProvider(t, reg, "public-capable", model, 100)
	setProviderVersion(public, "99.0.0")
	public.Mu().Lock()
	public.AccountID = "other"
	public.ToolConstraintProtocol = production.ToolConstraintProtocolV1
	public.ToolConstraintModels = map[string]struct{}{model: {}}
	public.Mu().Unlock()

	request := &production.QueuedRequest{
		RequestID:  "queued-self-route-constraint",
		Model:      model,
		ResponseCh: make(chan *production.Provider, 1),
		Pending: &production.PendingRequest{
			RequestID:          "queued-self-route-constraint",
			Model:              model,
			RequestedMaxTokens: 32,
			OwnerAccountID:     "owner",
			SelfRouteOnly:      true,
			Traits: production.RequestTraits{
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
		if !errors.Is(request.FailureReason, production.ErrQueueToolConstraintUnavailable) {
			t.Fatalf("failure = %v", request.FailureReason)
		}
	case <-time.After(time.Second):
		t.Fatal("self-route request waited on an unrelated capable provider")
	}
}

func TestQueuedPublicConstraintIgnoresPrivateOnlyProviders(t *testing.T) {
	reg := production.New(testLogger())
	model := "gemma-4-private-queue"
	private := makeSchedulerProvider(t, reg, "private-capable", model, 100)
	setProviderVersion(private, "99.0.0")
	private.Mu().Lock()
	private.PrivateOnly = true
	private.ToolConstraintProtocol = production.ToolConstraintProtocolV1
	private.ToolConstraintModels = map[string]struct{}{model: {}}
	private.Mu().Unlock()

	request := &production.QueuedRequest{
		RequestID:  "queued-public-constraint",
		Model:      model,
		ResponseCh: make(chan *production.Provider, 1),
		Pending: &production.PendingRequest{
			RequestID:          "queued-public-constraint",
			Model:              model,
			RequestedMaxTokens: 32,
			Traits: production.RequestTraits{
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
			t.Fatalf("private-only provider received public request: %s", selected.ID)
		}
		if !errors.Is(request.FailureReason, production.ErrQueueToolConstraintUnavailable) {
			t.Fatalf("failure = %v", request.FailureReason)
		}
	case <-time.After(time.Second):
		t.Fatal("public request waited on an unroutable private-only provider")
	}
}

func TestQueuedConstraintWaitsDuringCapableProviderReload(t *testing.T) {
	reg := production.New(testLogger())
	model := "gemma-4-reloading-queue"
	provider := makeSchedulerProvider(t, reg, "reloading-capable", model, 100)
	setProviderVersion(provider, "99.0.0")
	provider.Mu().Lock()
	provider.ToolConstraintProtocol = production.ToolConstraintProtocolV1
	provider.ToolConstraintModels = map[string]struct{}{model: {}}
	provider.BackendCapacity.Slots[0].State = "reloading"
	provider.Mu().Unlock()

	request := &production.QueuedRequest{
		RequestID:  "queued-reloading-constraint",
		Model:      model,
		ResponseCh: make(chan *production.Provider, 1),
		Pending: &production.PendingRequest{
			RequestID:          "queued-reloading-constraint",
			Model:              model,
			RequestedMaxTokens: 32,
			Traits: production.RequestTraits{
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
		t.Fatalf("reloading capable provider terminated waiter with %v", selected)
	default:
	}
	if request.FailureReason != nil {
		t.Fatalf("reloading capable provider set terminal failure: %v", request.FailureReason)
	}
}

func TestQueuedConstraintPreservesPrefixProtocolFloor(t *testing.T) {
	reg := production.New(testLogger())
	model := "gemma-4-prefix-protocol-queue"
	provider := makeSchedulerProvider(t, reg, "protocol-zero-capable", model, 100)
	setProviderVersion(provider, "99.0.0")
	provider.Mu().Lock()
	provider.PrefixCacheProtocol = 0
	provider.ToolConstraintProtocol = production.ToolConstraintProtocolV1
	provider.ToolConstraintModels = map[string]struct{}{model: {}}
	provider.Mu().Unlock()

	request := &production.QueuedRequest{
		RequestID:  "queued-prefix-protocol-constraint",
		Model:      model,
		ResponseCh: make(chan *production.Provider, 1),
		Pending: &production.PendingRequest{
			RequestID:          "queued-prefix-protocol-constraint",
			Model:              model,
			RequestedMaxTokens: 32,
			Traits: production.RequestTraits{
				HasTools:               true,
				RequiresToolConstraint: true,
				MinPrefixCacheProtocol: 1,
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
			t.Fatalf("protocol-zero provider received protocol-one request: %s", selected.ID)
		}
		if !errors.Is(request.FailureReason, production.ErrQueueToolConstraintUnavailable) {
			t.Fatalf("failure = %v", request.FailureReason)
		}
	case <-time.After(time.Second):
		t.Fatal("hard prefix protocol floor was dropped from capability check")
	}
}

func TestQueuedConstraintTerminatesWhenLastCapableProviderIsExcluded(t *testing.T) {
	reg := production.New(testLogger())
	model := "gemma-4-excluded"
	provider := makeSchedulerProvider(t, reg, "capable-excluded", model, 100)
	setProviderVersion(provider, "99.0.0")
	provider.Mu().Lock()
	provider.ToolConstraintProtocol = production.ToolConstraintProtocolV1
	provider.ToolConstraintModels = map[string]struct{}{model: {}}
	provider.Mu().Unlock()

	request := &production.QueuedRequest{
		RequestID:  "queued-excluded-constraint",
		Model:      model,
		ResponseCh: make(chan *production.Provider, 1),
		Pending: &production.PendingRequest{
			RequestID:           "queued-excluded-constraint",
			Model:               model,
			RequestedMaxTokens:  32,
			ExcludedProviderIDs: []string{provider.ID},
			Traits: production.RequestTraits{
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
			t.Fatalf("excluded provider received constrained request: %s", selected.ID)
		}
		if !errors.Is(request.FailureReason, production.ErrQueueToolConstraintUnavailable) {
			t.Fatalf("failure = %v", request.FailureReason)
		}
	case <-time.After(time.Second):
		t.Fatal("excluded-only capability kept constrained request queued")
	}
}

func TestQueuedConstraintTerminatesWhenLastCapableProviderDisconnects(t *testing.T) {
	reg := production.New(testLogger())
	model := "gemma-4-disconnect"
	provider := makeSchedulerProvider(t, reg, "capable", model, 100)
	provider.Mu().Lock()
	provider.ToolConstraintProtocol = production.ToolConstraintProtocolV1
	provider.ToolConstraintModels = map[string]struct{}{model: {}}
	provider.Mu().Unlock()

	request := &production.QueuedRequest{
		RequestID:  "queued-disconnect",
		Model:      model,
		ResponseCh: make(chan *production.Provider, 1),
		Pending: &production.PendingRequest{
			RequestID:          "queued-disconnect",
			Model:              model,
			RequestedMaxTokens: 32,
			Traits: production.RequestTraits{
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
		if !errors.Is(request.FailureReason, production.ErrQueueToolConstraintUnavailable) {
			t.Fatalf("failure = %v", request.FailureReason)
		}
	case <-time.After(time.Second):
		t.Fatal("disconnect left constrained request waiting for queue timeout")
	}
}

func TestModelsUpdateRefreshesConstraintRoutingImmediately(t *testing.T) {
	reg := production.New(testLogger())
	oldModel := "gemma-4-old"
	newModel := "gemma-4-hot"
	provider := makeSchedulerProvider(t, reg, "provider", oldModel, 100)
	setProviderVersion(provider, "99.0.0")
	provider.Mu().Lock()
	provider.AccountID = "owner"
	provider.ToolConstraintProtocol = production.ToolConstraintProtocolV1
	provider.ToolConstraintModels = map[string]struct{}{oldModel: {}}
	provider.Mu().Unlock()

	merged, _ := reg.MergeProviderModelsWithCapabilities(
		provider.ID,
		[]protocol.ModelInfo{{ID: newModel, ModelType: "gemma4_text"}},
		production.ToolConstraintProtocolV1,
		[]string{newModel},
	)
	if len(merged) != 1 || merged[0] != newModel {
		t.Fatalf("hot model merge = %#v", merged)
	}
	traits := production.RequestTraits{
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
	pending := &production.PendingRequest{
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
		production.ToolConstraintProtocolV1,
		[]string{},
	)
	if candidates, _, _ := reg.QuickCapacityCheck(
		newModel, 10, 32, traits,
	); candidates != 0 {
		t.Fatalf("removed hot capability still routed: %d", candidates)
	}
}

func TestAliasResolutionFallsBackToConstraintCapablePreviousBuild(t *testing.T) {
	reg := production.New(testLogger())
	desired := "gemma-4-desired"
	previous := "gemma-4-previous"
	desiredProvider := makeSchedulerProvider(t, reg, "desired-old", desired, 100)
	previousProvider := makeSchedulerProvider(t, reg, "previous-capable", previous, 100)
	setProviderVersion(desiredProvider, "0.7.10")
	setProviderVersion(previousProvider, "99.0.0")
	previousProvider.Mu().Lock()
	previousProvider.ToolConstraintProtocol = production.ToolConstraintProtocolV1
	previousProvider.ToolConstraintModels = map[string]struct{}{previous: {}}
	previousProvider.Mu().Unlock()
	reg.SetModelAliases(map[string]production.AliasTarget{
		"gemma-4": {Desired: desired, Previous: previous},
	})

	build, isAlias, ok := reg.ResolveModelConstrainedWithTraits(
		"gemma-4", nil, "", false, false,
		production.RequestTraits{HasTools: true, RequiresToolConstraint: true})
	if !ok || !isAlias || build != previous {
		t.Fatalf(
			"constrained alias resolved to build=%q alias=%v ok=%v, want previous %q",
			build, isAlias, ok, previous)
	}

	previousProvider.Mu().Lock()
	previousProvider.BackendCapacity.Slots[0].State = "reloading"
	previousProvider.Mu().Unlock()
	build, isAlias, ok = reg.ResolveModelConstrainedWithTraits(
		"gemma-4", nil, "", false, false,
		production.RequestTraits{HasTools: true, RequiresToolConstraint: true})
	if !ok || !isAlias || build != previous {
		t.Fatalf(
			"reloading capable previous resolved to build=%q alias=%v ok=%v, want %q",
			build, isAlias, ok, previous)
	}

	build, _, ok = reg.ResolveModelConstrainedWithTraits(
		"gemma-4", nil, "", false, false, production.RequestTraits{})
	if !ok || build != desired {
		t.Fatalf("ordinary alias resolved to %q ok=%v, want desired %q", build, ok, desired)
	}
}
