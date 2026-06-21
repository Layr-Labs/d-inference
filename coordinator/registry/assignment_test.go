package registry

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// addAssignableProvider inserts a minimal online provider for assignment tests.
func addAssignableProvider(r *Registry, id string) {
	r.mu.Lock()
	r.providers[id] = &Provider{ID: id, Status: StatusOnline}
	r.mu.Unlock()
}

func assignmentState(t *testing.T, r *Registry, id string) ProviderAssignment {
	t.Helper()
	snap, ok := r.ProviderAssignmentSnapshot(id)
	if !ok {
		t.Fatalf("provider %q not found for assignment snapshot", id)
	}
	return snap
}

func TestAssignProviderModelBumpsEpochAndState(t *testing.T) {
	r := New(testLogger())
	addAssignableProvider(r, "p1")

	epoch, changed, err := r.AssignProviderModel("p1", "gpt-oss-20b")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !changed || epoch != 1 {
		t.Fatalf("first assign: changed=%v epoch=%d, want true/1", changed, epoch)
	}
	snap := assignmentState(t, r, "p1")
	if snap.Model != "gpt-oss-20b" || snap.State != AssignmentStateLoading {
		t.Fatalf("snapshot=%+v, want model=gpt-oss-20b state=loading", snap)
	}
	if snap.AssignedAt.IsZero() {
		t.Fatal("AssignedAt not stamped")
	}

	// A switch to a different model bumps the epoch again.
	epoch2, changed2, _ := r.AssignProviderModel("p1", "gemma-4-26b")
	if !changed2 || epoch2 != 2 {
		t.Fatalf("switch assign: changed=%v epoch=%d, want true/2", changed2, epoch2)
	}
}

func TestAssignProviderModelIdempotentWhenAlreadyServing(t *testing.T) {
	r := New(testLogger())
	addAssignableProvider(r, "p1")

	epoch, _, _ := r.AssignProviderModel("p1", "gpt-oss-20b")
	// Provider confirms it is warm and serving.
	if !r.ApplyAssignModelStatus("p1", "gpt-oss-20b", epoch, protocol.AssignModelStatusSucceeded) {
		t.Fatal("succeeded status not applied")
	}
	if got := assignmentState(t, r, "p1").State; got != AssignmentStateAssigned {
		t.Fatalf("state=%q, want assigned", got)
	}

	// Re-assigning the same, already-serving model is a no-op: no epoch bump,
	// so the caller skips a redundant assign_model push.
	epoch2, changed, _ := r.AssignProviderModel("p1", "gpt-oss-20b")
	if changed || epoch2 != epoch {
		t.Fatalf("redundant assign: changed=%v epoch=%d, want false/%d", changed, epoch2, epoch)
	}
}

func TestApplyAssignModelStatusEpochGuard(t *testing.T) {
	r := New(testLogger())
	addAssignableProvider(r, "p1")

	// Assign twice → current epoch is 2.
	r.AssignProviderModel("p1", "gpt-oss-20b")
	epoch2, _, _ := r.AssignProviderModel("p1", "gemma-4-26b")

	// A stale ack from the superseded epoch-1 assignment is ignored.
	if r.ApplyAssignModelStatus("p1", "gpt-oss-20b", 1, protocol.AssignModelStatusSucceeded) {
		t.Fatal("stale-epoch status was applied")
	}
	// A status for the wrong model is ignored.
	if r.ApplyAssignModelStatus("p1", "whisper", epoch2, protocol.AssignModelStatusSucceeded) {
		t.Fatal("wrong-model status was applied")
	}
	// The current-epoch ack lands.
	if !r.ApplyAssignModelStatus("p1", "gemma-4-26b", epoch2, protocol.AssignModelStatusDraining) {
		t.Fatal("current-epoch draining status not applied")
	}
	if got := assignmentState(t, r, "p1").State; got != AssignmentStateDraining {
		t.Fatalf("state=%q, want draining", got)
	}
}

func TestApplyAssignModelStatusFailedArmsCooldownAndStaysIsolated(t *testing.T) {
	r := New(testLogger())
	addAssignableProvider(r, "p1")

	epoch, _, _ := r.AssignProviderModel("p1", "gemma-4-26b")
	if !r.ApplyAssignModelStatus("p1", "gemma-4-26b", epoch, protocol.AssignModelStatusFailed) {
		t.Fatal("failed status not applied")
	}

	snap := assignmentState(t, r, "p1")
	// Still bound to the model (no spillover) but not routing-eligible.
	if snap.Model != "gemma-4-26b" || snap.State != AssignmentStateFailed {
		t.Fatalf("snapshot=%+v, want model=gemma-4-26b state=failed", snap)
	}
	// The (provider,model) dispatch-load cooldown is armed.
	r.mu.RLock()
	active := r.dispatchLoadCooldownActiveLocked("p1", "gemma-4-26b", time.Now())
	r.mu.RUnlock()
	if !active {
		t.Fatal("failed assignment did not arm the dispatch-load cooldown")
	}
}

// registerProviderWithModels registers a routable-ready provider advertising
// several catalog models, so assignment-gate isolation can be tested
// independently of the catalog-membership gate.
func registerProviderWithModels(reg *Registry, id string, modelIDs ...string) *Provider {
	msg := testRegisterMessage()
	msg.Models = nil
	for _, m := range modelIDs {
		msg.Models = append(msg.Models, protocol.ModelInfo{ID: m, SizeBytes: 5_000_000_000, ModelType: "gemma", Quantization: "4bit"})
	}
	p := reg.Register(id, nil, msg)
	makeProviderRoutable(p)
	return p
}

func TestAssignmentGateIsolatesPools(t *testing.T) {
	reg := New(testLogger())
	const mA, mB = "model-a", "model-b"
	p := registerProviderWithModels(reg, "p1", mA, mB)
	now := time.Now()

	// Gate disabled (default): an unmanaged provider serves both models.
	if !reg.providerPassesRoutingGatesLockedEx(p, mA, RequestTraits{}, false, now, false) ||
		!reg.providerPassesRoutingGatesLockedEx(p, mB, RequestTraits{}, false, now, false) {
		t.Fatal("unmanaged provider should serve both catalog models")
	}

	// Enable isolation + assign to A (live/serving).
	reg.SetAssignmentGateEnabled(true)
	epoch, _, _ := reg.AssignProviderModel("p1", mA)
	reg.ApplyAssignModelStatus("p1", mA, epoch, protocol.AssignModelStatusSucceeded)

	if !reg.providerPassesRoutingGatesLockedEx(p, mA, RequestTraits{}, false, now, false) {
		t.Fatal("assigned provider should serve its model A")
	}
	if reg.providerPassesRoutingGatesLockedEx(p, mB, RequestTraits{}, false, now, false) {
		t.Fatal("assigned provider must NOT serve model B (no spillover)")
	}
	// Self-route owner bypasses the gate (never filtered into no-candidate).
	if !reg.providerPassesRoutingGatesLockedEx(p, mB, RequestTraits{}, true, now, false) {
		t.Fatal("self-route owner should bypass the assignment gate")
	}
	// Kill switch off → no restriction again.
	reg.SetAssignmentGateEnabled(false)
	if !reg.providerPassesRoutingGatesLockedEx(p, mB, RequestTraits{}, false, now, false) {
		t.Fatal("disabling the gate should drop pool isolation")
	}
}

func TestAssignmentGateExcludesMidTransition(t *testing.T) {
	reg := New(testLogger())
	const mA = "model-a"
	p := registerProviderWithModels(reg, "p1", mA)
	reg.SetAssignmentGateEnabled(true)
	now := time.Now()

	// Loading (assigned but not yet warm) → excluded from routing.
	epoch, _, _ := reg.AssignProviderModel("p1", mA)
	if reg.providerPassesRoutingGatesLockedEx(p, mA, RequestTraits{}, false, now, false) {
		t.Fatal("provider mid-load must not be routing-eligible")
	}
	// Once it confirms warm → eligible.
	reg.ApplyAssignModelStatus("p1", mA, epoch, protocol.AssignModelStatusSucceeded)
	if !reg.providerPassesRoutingGatesLockedEx(p, mA, RequestTraits{}, false, now, false) {
		t.Fatal("provider should be eligible once the assignment succeeds")
	}
}

func TestPoolExhausted(t *testing.T) {
	reg := New(testLogger())
	const mA, mB = "model-a", "model-b"

	// Gate off: never exhausted (no enforcement).
	p1 := registerProviderWithModels(reg, "p1", mA, mB)
	if ex, _ := reg.PoolExhausted(mA); ex {
		t.Fatal("gate disabled must report not-exhausted")
	}

	reg.SetAssignmentGateEnabled(true)

	// p1 (has both on disk) is assigned to A and serving. Pool A has a serving
	// machine → not exhausted. Pool B has zero serving but is catalog-capable on
	// p1 → exhausted.
	epoch, _, _ := reg.AssignProviderModel("p1", mA)
	reg.ApplyAssignModelStatus("p1", mA, epoch, protocol.AssignModelStatusSucceeded)

	if ex, _ := reg.PoolExhausted(mA); ex {
		t.Fatal("pool A has a serving machine; must not be exhausted")
	}
	exB, capable := reg.PoolExhausted(mB)
	if !exB || capable < 1 {
		t.Fatalf("pool B exhausted=%v catalogCapable=%d, want true/>=1", exB, capable)
	}

	// A model no provider has on disk is NOT pool_exhausted (a different
	// rejection — model_not_found / no_provider).
	if ex, _ := reg.PoolExhausted("model-c"); ex {
		t.Fatal("model with no catalog-capable provider must not be pool_exhausted")
	}

	// Once a machine is assigned+serving B, pool B is no longer exhausted.
	_ = p1
	epochB, _, _ := reg.AssignProviderModel("p1", mB)
	reg.ApplyAssignModelStatus("p1", mB, epochB, protocol.AssignModelStatusSucceeded)
	if ex, _ := reg.PoolExhausted(mB); ex {
		t.Fatal("pool B now has a serving machine; must not be exhausted")
	}
}

// TestPoolExhaustedMixedFleetNoFalsePositive guards the rollout case (review
// finding #1): an UNMANAGED machine that serves the model is routing-eligible,
// so the pool is NOT exhausted even when no managed machine is assigned it.
func TestPoolExhaustedMixedFleetNoFalsePositive(t *testing.T) {
	reg := New(testLogger())
	reg.SetAssignmentGateEnabled(true)
	const mA, mB = "model-a", "model-b"

	// p1 managed → assigned + serving A. p2 left UNMANAGED, serving both.
	p1 := registerProviderWithModels(reg, "p1", mA, mB)
	_ = registerProviderWithModels(reg, "p2", mA, mB)
	epoch, _, _ := reg.AssignProviderModel(p1.ID, mA)
	reg.ApplyAssignModelStatus(p1.ID, mA, epoch, protocol.AssignModelStatusSucceeded)

	// Pool B has no MANAGED machine, but the unmanaged p2 serves it and the gate
	// would route there → NOT exhausted (no false 429).
	if ex, _ := reg.PoolExhausted(mB); ex {
		t.Fatal("unmanaged machine serving B must make pool B not-exhausted")
	}

	// Now manage p2 too, assigned to A → no eligible machine for B → exhausted.
	epoch2, _, _ := reg.AssignProviderModel("p2", mA)
	reg.ApplyAssignModelStatus("p2", mA, epoch2, protocol.AssignModelStatusSucceeded)
	if ex, _ := reg.PoolExhausted(mB); !ex {
		t.Fatal("with both machines managed onto A, pool B must be exhausted")
	}
}

func TestModelPoolReport(t *testing.T) {
	reg := New(testLogger())
	reg.SetAssignmentGateEnabled(true)
	const mA, mB = "model-a", "model-b"

	// p1 managed → assigned A. p2 unmanaged but holding TWO warm models (the
	// co-residency the pools are meant to eliminate).
	p1 := registerProviderWithModels(reg, "p1", mA, mB)
	epoch, _, _ := reg.AssignProviderModel(p1.ID, mA)
	reg.ApplyAssignModelStatus(p1.ID, mA, epoch, protocol.AssignModelStatusSucceeded)
	p2 := registerProviderWithModels(reg, "p2", mA, mB)
	p2.mu.Lock()
	p2.WarmModels = []string{mA, mB}
	p2.mu.Unlock()

	rep := reg.ModelPoolReport()
	if !rep.GateEnabled {
		t.Fatal("report should reflect the enabled gate")
	}
	if rep.ManagedProviders != 1 {
		t.Fatalf("ManagedProviders=%d, want 1", rep.ManagedProviders)
	}
	if rep.CoResidentProviders != 1 {
		t.Fatalf("CoResidentProviders=%d, want 1 (p2 holds 2 warm models)", rep.CoResidentProviders)
	}
	if len(rep.Providers) != 2 {
		t.Fatalf("expected 2 provider entries, got %d", len(rep.Providers))
	}
}

func TestSendAssignModelUsesSenderSeam(t *testing.T) {
	r := New(testLogger())
	var gotProvider, gotModel string
	var gotEpoch uint64
	r.assignModelSender = func(providerID, modelID string, epoch uint64) error {
		gotProvider, gotModel, gotEpoch = providerID, modelID, epoch
		return nil
	}
	if err := r.SendAssignModel("p1", "gpt-oss-20b", 7); err != nil {
		t.Fatalf("SendAssignModel: %v", err)
	}
	if gotProvider != "p1" || gotModel != "gpt-oss-20b" || gotEpoch != 7 {
		t.Fatalf("seam saw provider=%q model=%q epoch=%d", gotProvider, gotModel, gotEpoch)
	}
}
