package sandboxcontrol

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/sandboxhost"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestSweepExpiredCommandsPersistsTimeout(t *testing.T) {
	ctx := context.Background()
	now := time.Date(2026, 8, 25, 2, 0, 0, 0, time.UTC)
	backend := store.NewMemory(store.Config{})
	sandbox := &store.SandboxRecord{
		ID:                    "10000000-0000-0000-0000-000000000001",
		AccountID:             "account-1",
		IdempotencyKey:        "20000000-0000-0000-0000-000000000002",
		HostID:                "30000000-0000-0000-0000-000000000003",
		Generation:            1,
		FencingToken:          1,
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
		ID:                      "40000000-0000-0000-0000-000000000004",
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
	if _, _, err := backend.ApplySandboxOperationUpdate(
		ctx,
		store.SandboxOperationUpdate{
			OperationID:  prepare.ID,
			SandboxID:    sandbox.ID,
			Generation:   sandbox.Generation,
			FencingToken: sandbox.FencingToken,
			State:        store.SandboxOperationReady,
			UpdatedAt:    now.Add(-30 * time.Second),
		},
	); err != nil {
		t.Fatalf("ready sandbox: %v", err)
	}
	command := &store.SandboxCommand{
		ID:             "50000000-0000-0000-0000-000000000005",
		SandboxID:      sandbox.ID,
		AccountID:      sandbox.AccountID,
		IdempotencyKey: "60000000-0000-0000-0000-000000000006",
		Generation:     sandbox.Generation,
		FencingToken:   sandbox.FencingToken,
		Arguments:      []string{"/usr/bin/true"},
		TimeoutSeconds: 1,
		State:          store.SandboxCommandPending,
		CreatedAt:      now.Add(-2 * time.Second),
		UpdatedAt:      now.Add(-2 * time.Second),
	}
	if _, created, err := backend.CreateSandboxCommand(ctx, command); err != nil ||
		!created {
		t.Fatalf("create command: created=%v error=%v", created, err)
	}
	if _, err := backend.ApplySandboxCommandUpdate(
		ctx,
		store.SandboxCommandUpdate{
			CommandID:    command.ID,
			SandboxID:    sandbox.ID,
			Generation:   sandbox.Generation,
			FencingToken: sandbox.FencingToken,
			State:        store.SandboxCommandRunning,
			UpdatedAt:    now.Add(-1500 * time.Millisecond),
		},
	); err != nil {
		t.Fatalf("run command: %v", err)
	}

	controller := &Controller{
		store: backend,
		hosts: sandboxhost.NewRegistry(nil),
		now:   func() time.Time { return now },
	}
	if err := controller.sweepExpiredCommands(ctx); err != nil {
		t.Fatalf("sweep commands: %v", err)
	}
	stored, err := backend.GetSandboxCommand(
		ctx,
		sandbox.AccountID,
		sandbox.ID,
		command.ID,
	)
	if err != nil {
		t.Fatalf("get command: %v", err)
	}
	if stored.State != store.SandboxCommandTimedOut ||
		stored.ErrorCode != "command_deadline_exceeded" ||
		stored.CompletedAt == nil ||
		!stored.CompletedAt.Equal(now) {
		t.Fatalf("timed-out command = %+v", stored)
	}
}
