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

func TestQueuedPublicConstraintIgnoresPrivateOnlyProviders(t *testing.T) {
	reg := New(testLogger())
	model := "gemma-4-private-queue"
	private := makeSchedulerProvider(t, reg, "private-capable", model, 100)
	setProviderVersion(private, "99.0.0")
	private.mu.Lock()
	private.PrivateOnly = true
	private.ToolConstraintProtocol = ToolConstraintProtocolV1
	private.ToolConstraintModels = map[string]struct{}{model: {}}
	private.mu.Unlock()

	request := &QueuedRequest{
		RequestID:  "queued-public-constraint",
		Model:      model,
		ResponseCh: make(chan *Provider, 1),
		Pending: &PendingRequest{
			RequestID:          "queued-public-constraint",
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
	case selected := <-request.ResponseCh:
		if selected != nil {
			t.Fatalf("private-only provider received public request: %s", selected.ID)
		}
		if !errors.Is(request.FailureReason, ErrQueueToolConstraintUnavailable) {
			t.Fatalf("failure = %v", request.FailureReason)
		}
	case <-time.After(time.Second):
		t.Fatal("public request waited on an unroutable private-only provider")
	}
}

func TestQueuedConstraintWaitsDuringCapableProviderReload(t *testing.T) {
	reg := New(testLogger())
	model := "gemma-4-reloading-queue"
	provider := makeSchedulerProvider(t, reg, "reloading-capable", model, 100)
	setProviderVersion(provider, "99.0.0")
	provider.mu.Lock()
	provider.ToolConstraintProtocol = ToolConstraintProtocolV1
	provider.ToolConstraintModels = map[string]struct{}{model: {}}
	provider.BackendCapacity.Slots[0].State = "reloading"
	provider.mu.Unlock()

	request := &QueuedRequest{
		RequestID:  "queued-reloading-constraint",
		Model:      model,
		ResponseCh: make(chan *Provider, 1),
		Pending: &PendingRequest{
			RequestID:          "queued-reloading-constraint",
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
	case selected := <-request.ResponseCh:
		t.Fatalf("reloading capable provider terminated waiter with %v", selected)
	default:
	}
	if request.FailureReason != nil {
		t.Fatalf("reloading capable provider set terminal failure: %v", request.FailureReason)
	}
}

func TestConstraintAvailabilityPreservesResidentHardwareFitBypass(t *testing.T) {
	reg := New(testLogger())
	model := "gemma-4-resident-oversized"
	reg.SetModelCatalog([]CatalogEntry{{
		ID: model, SizeGB: 100, MinRAMGB: 128,
	}})
	provider := makeSchedulerProvider(t, reg, "resident-capable", model, 100)
	setProviderVersion(provider, "99.0.0")
	provider.mu.Lock()
	provider.ToolConstraintProtocol = ToolConstraintProtocolV1
	provider.ToolConstraintModels = map[string]struct{}{model: {}}
	provider.mu.Unlock()

	pending := &PendingRequest{
		Model: model,
		Traits: RequestTraits{
			HasTools: true, RequiresToolConstraint: true,
		},
	}
	if !reg.hasToolConstraintProviderForPending(model, pending) {
		t.Fatal("resident capable provider was rejected by cold hardware heuristic")
	}
}

func TestConstraintAvailabilityUsesOwnerOffCatalogModelSize(t *testing.T) {
	reg := New(testLogger())
	model := "owner-local-oversized"
	reg.SetModelCatalog([]CatalogEntry{{ID: "unrelated-catalog-build"}})
	provider := makeSchedulerProvider(t, reg, "owner-local", model, 100)
	setProviderVersion(provider, "99.0.0")
	provider.mu.Lock()
	provider.AccountID = "owner"
	provider.PrivateOnly = true
	provider.Models[0].SizeBytes = 100 << 30
	provider.ToolConstraintProtocol = ToolConstraintProtocolV1
	provider.ToolConstraintModels = map[string]struct{}{model: {}}
	provider.BackendCapacity.Slots[0].State = "idle_shutdown"
	provider.mu.Unlock()

	pending := &PendingRequest{
		Model:          model,
		OwnerAccountID: "owner",
		SelfRouteOnly:  true,
		Traits: RequestTraits{
			HasTools: true, RequiresToolConstraint: true,
		},
	}
	if reg.hasToolConstraintProviderForPending(model, pending) {
		t.Fatal("oversized owner-local model bypassed advertised-size hardware fit")
	}
}

func TestQueuedConstraintPreservesPrefixProtocolFloor(t *testing.T) {
	reg := New(testLogger())
	model := "gemma-4-prefix-protocol-queue"
	provider := makeSchedulerProvider(t, reg, "protocol-zero-capable", model, 100)
	setProviderVersion(provider, "99.0.0")
	provider.mu.Lock()
	provider.PrefixCacheProtocol = 0
	provider.ToolConstraintProtocol = ToolConstraintProtocolV1
	provider.ToolConstraintModels = map[string]struct{}{model: {}}
	provider.mu.Unlock()

	request := &QueuedRequest{
		RequestID:  "queued-prefix-protocol-constraint",
		Model:      model,
		ResponseCh: make(chan *Provider, 1),
		Pending: &PendingRequest{
			RequestID:          "queued-prefix-protocol-constraint",
			Model:              model,
			RequestedMaxTokens: 32,
			Traits: RequestTraits{
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
		if !errors.Is(request.FailureReason, ErrQueueToolConstraintUnavailable) {
			t.Fatalf("failure = %v", request.FailureReason)
		}
	case <-time.After(time.Second):
		t.Fatal("hard prefix protocol floor was dropped from capability check")
	}
}

func TestQueuedConstraintTerminatesWhenLastCapableProviderIsExcluded(t *testing.T) {
	reg := New(testLogger())
	model := "gemma-4-excluded"
	provider := makeSchedulerProvider(t, reg, "capable-excluded", model, 100)
	setProviderVersion(provider, "99.0.0")
	provider.mu.Lock()
	provider.ToolConstraintProtocol = ToolConstraintProtocolV1
	provider.ToolConstraintModels = map[string]struct{}{model: {}}
	provider.mu.Unlock()

	request := &QueuedRequest{
		RequestID:  "queued-excluded-constraint",
		Model:      model,
		ResponseCh: make(chan *Provider, 1),
		Pending: &PendingRequest{
			RequestID:           "queued-excluded-constraint",
			Model:               model,
			RequestedMaxTokens:  32,
			ExcludedProviderIDs: []string{provider.ID},
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
			t.Fatalf("excluded provider received constrained request: %s", selected.ID)
		}
		if !errors.Is(request.FailureReason, ErrQueueToolConstraintUnavailable) {
			t.Fatalf("failure = %v", request.FailureReason)
		}
	case <-time.After(time.Second):
		t.Fatal("excluded-only capability kept constrained request queued")
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

	previousProvider.mu.Lock()
	previousProvider.BackendCapacity.Slots[0].State = "reloading"
	previousProvider.mu.Unlock()
	build, isAlias, ok = reg.ResolveModelConstrainedWithTraits(
		"gemma-4", nil, "", false, false,
		RequestTraits{HasTools: true, RequiresToolConstraint: true})
	if !ok || !isAlias || build != previous {
		t.Fatalf(
			"reloading capable previous resolved to build=%q alias=%v ok=%v, want %q",
			build, isAlias, ok, previous)
	}

	build, _, ok = reg.ResolveModelConstrainedWithTraits(
		"gemma-4", nil, "", false, false, RequestTraits{})
	if !ok || build != desired {
		t.Fatalf("ordinary alias resolved to %q ok=%v, want desired %q", build, ok, desired)
	}
}

// tool_choice "none" is honored PROMPT-SIDE: ToolChoicePromptPolicy hides the
// declared tools from the rendered prompt and injects the no-tool
// instruction, and that policy first shipped in provider v0.7.10 (#538). A
// tool-declaring `none` request must never route to an older provider — it
// renders the tools verbatim and can emit a call despite the caller's
// explicit `none`; the fleet-wide minimum version does not cover this. Other
// modes and tool-less `none` are untouched by the floor.
func TestToolChoiceNoneRequiresPromptPolicyVersionFloor(t *testing.T) {
	reg := New(testLogger())
	model := "none-floor-model"
	provider := makeSchedulerProvider(t, reg, "provider", model, 100)
	setProviderVersion(provider, "0.7.9")

	noneTraits := RequestTraits{HasTools: true, ToolChoiceMode: "none"}
	if reg.HasToolCapableProviderForTraits(model, noneTraits) {
		t.Fatal("0.7.9 pre-dates ToolChoicePromptPolicy and must not serve tools + none")
	}
	if !reg.HasToolCapableProviderForTraits(
		model, RequestTraits{HasTools: true, ToolChoiceMode: "auto"}) {
		t.Fatal("auto at 0.7.9 must be unaffected by the none floor")
	}
	if !reg.HasToolCapableProviderForTraits(
		model, RequestTraits{HasTools: true, ToolChoiceMode: "required"}) {
		t.Fatal("required at 0.7.9 must be unaffected by the none floor")
	}
	// Tool-less none: nothing is declared, so there is nothing to hide.
	if !reg.HasToolCapableProviderForTraits(
		model, RequestTraits{ToolChoiceMode: "none"}) {
		t.Fatal("tool-less none must not be version-fenced")
	}

	setProviderVersion(provider, "0.7.10")
	if !reg.HasToolCapableProviderForTraits(model, noneTraits) {
		t.Fatal("0.7.10 ships the prompt policy and must serve tools + none")
	}
}
