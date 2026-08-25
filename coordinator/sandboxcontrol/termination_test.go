package sandboxcontrol

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/sandboxhost"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestTerminationRecoversStopDeleteCrashGap(t *testing.T) {
	ctx := context.Background()
	now := time.Date(2026, 8, 25, 4, 0, 0, 0, time.UTC)
	backend := store.NewMemory(store.Config{})
	sandbox := createReadyTestSandbox(t, backend, now)
	controller := testSandboxController(backend, &now)
	rootKey := "60000000-0000-0000-0000-000000000106"
	terminating, err := backend.MarkSandboxTerminationRequested(
		ctx,
		sandbox.AccountID,
		sandbox.ID,
		rootKey,
		now,
	)
	if err != nil {
		t.Fatalf("mark termination: %v", err)
	}
	stop, err := controller.beginTerminationStage(
		ctx,
		terminating,
		store.SandboxOperationKindStop,
	)
	if err != nil {
		t.Fatalf("begin termination stop: %v", err)
	}
	if stop.IdempotencyKey == rootKey {
		t.Fatal("termination stop reused the public idempotency key")
	}
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

	now = now.Add(2 * time.Second)
	if err := controller.driveTermination(ctx, stopped); err != nil {
		t.Fatalf("recover delete after stop crash gap: %v", err)
	}
	pending, err := backend.ListPendingSandboxOperationsByHost(
		ctx,
		sandbox.HostID,
	)
	if err != nil {
		t.Fatalf("list pending operations: %v", err)
	}
	if len(pending) != 1 ||
		pending[0].Operation.Kind != store.SandboxOperationKindDelete ||
		pending[0].Operation.IdempotencyKey == rootKey ||
		pending[0].Operation.IdempotencyKey == stop.IdempotencyKey {
		t.Fatalf("recovered delete operation = %+v", pending)
	}
}

func TestTerminationRetriesFailedStagesWithNewAuthority(t *testing.T) {
	ctx := context.Background()
	now := time.Date(2026, 8, 25, 5, 0, 0, 0, time.UTC)
	backend := store.NewMemory(store.Config{})
	sandbox := createReadyTestSandbox(t, backend, now)
	controller := testSandboxController(backend, &now)
	terminating, err := backend.MarkSandboxTerminationRequested(
		ctx,
		sandbox.AccountID,
		sandbox.ID,
		"70000000-0000-0000-0000-000000000107",
		now,
	)
	if err != nil {
		t.Fatalf("mark termination: %v", err)
	}
	first, err := controller.beginTerminationStage(
		ctx,
		terminating,
		store.SandboxOperationKindStop,
	)
	if err != nil {
		t.Fatalf("begin first stop: %v", err)
	}
	failed, _, err := backend.ApplySandboxOperationUpdate(
		ctx,
		store.SandboxOperationUpdate{
			OperationID:  first.ID,
			SandboxID:    sandbox.ID,
			Generation:   sandbox.Generation,
			FencingToken: sandbox.FencingToken,
			State:        store.SandboxOperationFailed,
			ErrorCode:    "transient_stop_failure",
			UpdatedAt:    now.Add(time.Second),
		},
	)
	if err != nil {
		t.Fatalf("fail first stop: %v", err)
	}

	now = now.Add(dispatchRetryInterval + 2*time.Second)
	if err := controller.driveTermination(ctx, failed); err != nil {
		t.Fatalf("retry failed stop: %v", err)
	}
	pending, err := backend.ListPendingSandboxOperationsByHost(
		ctx,
		sandbox.HostID,
	)
	if err != nil {
		t.Fatalf("list retried stop: %v", err)
	}
	if len(pending) != 1 ||
		pending[0].Operation.Kind != store.SandboxOperationKindStop ||
		pending[0].Operation.ID == first.ID ||
		pending[0].Operation.IdempotencyKey == first.IdempotencyKey {
		t.Fatalf("retried stop operation = %+v", pending)
	}
}

func testSandboxController(
	backend store.SandboxStore,
	now *time.Time,
) *Controller {
	return &Controller{
		store:           backend,
		hosts:           sandboxhost.NewRegistry(nil),
		now:             func() time.Time { return *now },
		hostNextFence:   make(map[string]uint64),
		reconciledEpoch: make(map[string]string),
	}
}

func createReadyTestSandbox(
	t *testing.T,
	backend store.SandboxStore,
	now time.Time,
) *store.SandboxRecord {
	t.Helper()
	ctx := context.Background()
	sandbox := &store.SandboxRecord{
		ID:                    "10000000-0000-0000-0000-000000000101",
		AccountID:             "termination-test-account",
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
		CreatedAt:             now.Add(-time.Minute),
		UpdatedAt:             now.Add(-time.Minute),
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
		CreatedAt:               sandbox.CreatedAt,
		UpdatedAt:               sandbox.UpdatedAt,
	}
	if _, _, _, err := backend.CreateSandbox(
		ctx,
		sandbox,
		prepare,
		store.SandboxAllocationLimits{
			MaximumActive:     2,
			MaximumPerAccount: 2,
			MaximumPerHost:    2,
		},
	); err != nil {
		t.Fatalf("create sandbox: %v", err)
	}
	ready, _, err := backend.ApplySandboxOperationUpdate(
		ctx,
		store.SandboxOperationUpdate{
			OperationID:  prepare.ID,
			SandboxID:    sandbox.ID,
			Generation:   sandbox.Generation,
			FencingToken: sandbox.FencingToken,
			State:        store.SandboxOperationReady,
			UpdatedAt:    now.Add(-30 * time.Second),
		},
	)
	if err != nil {
		t.Fatalf("ready sandbox: %v", err)
	}
	return ready
}
