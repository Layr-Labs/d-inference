package sandboxcontrol

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestHeartbeatLifecycleObservationRequiresExactLeaseExpiry(t *testing.T) {
	ctx := context.Background()
	now := time.Date(2026, 8, 25, 12, 0, 0, 0, time.UTC)
	backend := store.NewMemory(store.Config{})
	sandbox := createReadyTestSandbox(t, backend, now)
	controller := testSandboxController(backend, &now)

	stop, err := controller.beginStop(
		ctx,
		sandbox,
		false,
		"70000000-0000-0000-0000-000000000107",
	)
	if err != nil {
		t.Fatalf("begin stop: %v", err)
	}
	stopping, err := backend.GetSandboxByID(ctx, sandbox.ID)
	if err != nil {
		t.Fatalf("get stopping sandbox: %v", err)
	}
	assertHeartbeatExpiryDriftRejected(
		t,
		controller,
		&store.PendingSandboxOperation{
			Sandbox:   *stopping,
			Operation: *stop,
		},
		protocol.SandboxOperationStopped,
	)

	stopped, _, err := backend.ApplySandboxOperationUpdate(
		ctx,
		store.SandboxOperationUpdate{
			OperationID:  stop.ID,
			SandboxID:    sandbox.ID,
			Generation:   sandbox.Generation,
			FencingToken: sandbox.FencingToken,
			State:        store.SandboxOperationStopped,
			UpdatedAt:    now.Add(time.Second),
		},
	)
	if err != nil {
		t.Fatalf("complete stop: %v", err)
	}
	deletion, err := controller.beginDelete(
		ctx,
		stopped,
		"80000000-0000-0000-0000-000000000108",
	)
	if err != nil {
		t.Fatalf("begin delete: %v", err)
	}
	deleting, err := backend.GetSandboxByID(ctx, sandbox.ID)
	if err != nil {
		t.Fatalf("get deleting sandbox: %v", err)
	}
	assertHeartbeatExpiryDriftRejected(
		t,
		controller,
		&store.PendingSandboxOperation{
			Sandbox:   *deleting,
			Operation: *deletion,
		},
		protocol.SandboxOperationDeleting,
	)
	confirmed, err := controller.applyHeartbeatOperationObservation(
		ctx,
		&store.PendingSandboxOperation{
			Sandbox:   *deleting,
			Operation: *deletion,
		},
		heartbeatObservation(deleting, protocol.SandboxOperationDeleting),
	)
	if err != nil || !confirmed {
		t.Fatalf("exact delete observation: confirmed=%v error=%v", confirmed, err)
	}
}

func TestHeartbeatPrepareFailureStartsCleanup(t *testing.T) {
	ctx := context.Background()
	now := time.Date(2026, 8, 25, 13, 0, 0, 0, time.UTC)
	backend := store.NewMemory(store.Config{})
	sandbox := &store.SandboxRecord{
		ID:                    "10000000-0000-0000-0000-000000000101",
		AccountID:             "reconcile-test-account",
		IdempotencyKey:        "20000000-0000-0000-0000-000000000102",
		HostID:                "30000000-0000-0000-0000-000000000103",
		Generation:            1,
		FencingToken:          10,
		BaseImageID:           "macos-tahoe-v1",
		CPUCount:              4,
		MemoryBytes:           8 << 30,
		WorkspaceBytes:        25 << 30,
		CommandTimeoutSeconds: 900,
		State:                 store.SandboxStatePreparing,
		LeaseExpiresAt:        now.Add(time.Hour),
		CreatedAt:             now,
		UpdatedAt:             now,
	}
	prepare := &store.SandboxOperation{
		ID:                      "40000000-0000-0000-0000-000000000104",
		SandboxID:               sandbox.ID,
		AccountID:               sandbox.AccountID,
		IdempotencyKey:          sandbox.IdempotencyKey,
		Kind:                    store.SandboxOperationKindPrepare,
		State:                   store.SandboxOperationPending,
		Generation:              sandbox.Generation,
		FencingToken:            sandbox.FencingToken,
		RequestedLeaseExpiresAt: sandbox.LeaseExpiresAt,
		CreatedAt:               now,
		UpdatedAt:               now,
	}
	storedSandbox, storedPrepare, _, err := backend.CreateSandbox(
		ctx,
		sandbox,
		prepare,
		store.SandboxAllocationLimits{
			MaximumActive:     2,
			MaximumPerAccount: 2,
			MaximumPerHost:    2,
		},
	)
	if err != nil {
		t.Fatalf("create preparing sandbox: %v", err)
	}
	controller := testSandboxController(backend, &now)
	confirmed, err := controller.applyHeartbeatOperationObservation(
		ctx,
		&store.PendingSandboxOperation{
			Sandbox:   *storedSandbox,
			Operation: *storedPrepare,
		},
		heartbeatObservation(storedSandbox, protocol.SandboxOperationFailed),
	)
	if err != nil || !confirmed {
		t.Fatalf("apply prepare failure: confirmed=%v error=%v", confirmed, err)
	}
	updated, err := backend.GetSandboxByID(ctx, sandbox.ID)
	if err != nil {
		t.Fatalf("get cleanup sandbox: %v", err)
	}
	if !updated.TerminationRequested ||
		updated.State != store.SandboxStateDeleting {
		t.Fatalf("prepare failure cleanup state = %+v", updated)
	}
	pending, err := backend.ListPendingSandboxOperationsByHost(
		ctx,
		sandbox.HostID,
	)
	if err != nil {
		t.Fatalf("list cleanup operations: %v", err)
	}
	if len(pending) != 1 ||
		pending[0].Operation.Kind != store.SandboxOperationKindDelete {
		t.Fatalf("prepare failure cleanup operations = %+v", pending)
	}
}

func assertHeartbeatExpiryDriftRejected(
	t *testing.T,
	controller *Controller,
	pending *store.PendingSandboxOperation,
	state string,
) {
	t.Helper()
	observation := heartbeatObservation(&pending.Sandbox, state)
	observation.LeaseExpiresAt = pending.Sandbox.LeaseExpiresAt.
		Add(time.Second).
		Format(time.RFC3339Nano)
	confirmed, err := controller.applyHeartbeatOperationObservation(
		context.Background(),
		pending,
		observation,
	)
	if err != nil || confirmed {
		t.Fatalf("expiry drift result = (%v, %v), want (false, nil)", confirmed, err)
	}
	stored, err := controller.store.GetSandboxOperation(
		context.Background(),
		pending.Operation.AccountID,
		pending.Operation.ID,
	)
	if err != nil {
		t.Fatalf("get operation after drift: %v", err)
	}
	if stored.State != store.SandboxOperationPending {
		t.Fatalf("expiry drift advanced operation to %q", stored.State)
	}
}

func heartbeatObservation(
	sandbox *store.SandboxRecord,
	state string,
) protocol.SandboxHostLeaseObservation {
	return protocol.SandboxHostLeaseObservation{
		Scope: protocol.SandboxScope{
			SandboxID:    sandbox.ID,
			Generation:   sandbox.Generation,
			FencingToken: sandbox.FencingToken,
		},
		State: state,
		Resources: protocol.SandboxResources{
			CPUCount:              sandbox.CPUCount,
			MemoryBytes:           sandbox.MemoryBytes,
			WorkspaceBytes:        sandbox.WorkspaceBytes,
			CommandTimeoutSeconds: sandbox.CommandTimeoutSeconds,
			GPU:                   sandbox.GPU,
		},
		LeaseExpiresAt: sandbox.LeaseExpiresAt.Format(time.RFC3339Nano),
	}
}
