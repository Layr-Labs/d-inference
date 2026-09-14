package sandboxcontrol

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

func TestSandboxUserCancellationPersistsUntilHostAcknowledgement(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Millisecond)
	backend := store.NewCached(store.NewMemory(store.Config{}), store.CacheConfig{})
	sandbox := createReadyTestSandbox(t, backend, now)
	controller := testSandboxController(backend, &now)
	command, err := controller.Execute(ctx, sandbox.AccountID, sandbox.ID, CommandRequest{
		IdempotencyKey: uuid.NewString(), Arguments: []string{"/usr/bin/sleep", "60"}, TimeoutSeconds: 60,
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := controller.CancelCommand(ctx, "other-account", sandbox.ID, command.ID); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("cross-account cancellation: %v", err)
	}
	cancelled, err := controller.CancelCommand(ctx, sandbox.AccountID, sandbox.ID, command.ID)
	if err != nil || cancelled.State != store.SandboxCommandCancelled || !cancelled.CancellationPending || cancelled.ErrorCode != "cancelled_by_user" {
		t.Fatalf("cancelled=%+v error=%v", cancelled, err)
	}
	if _, err := controller.Execute(ctx, sandbox.AccountID, sandbox.ID, CommandRequest{
		IdempotencyKey: uuid.NewString(), Arguments: []string{"/usr/bin/true"},
	}); !errors.Is(err, store.ErrSandboxConflict) {
		t.Fatalf("new command admitted before cleanup: %v", err)
	}
	replayed, err := controller.CancelCommand(ctx, sandbox.AccountID, sandbox.ID, command.ID)
	if err != nil || replayed.CancelDispatchAttempts != cancelled.CancelDispatchAttempts {
		t.Fatalf("repeated cancellation changed delivery claim: %+v %v", replayed, err)
	}
	transport := &cancellationTestTransport{}
	session := registerCancellationTestHost(t, controller.hosts, sandbox, uuid.NewString(), transport)
	if err := controller.reconcileHost(ctx, session, &protocol.SandboxHostHeartbeatPayload{}); err != nil {
		t.Fatal(err)
	}
	if len(transport.frames()) != 1 {
		t.Fatal("reconnected host did not receive durable cancellation")
	}
	if err := controller.handleCommandState(ctx, session, &protocol.SandboxCommandStatePayload{
		CommandID: command.ID, Scope: sandboxScope(sandbox), State: store.SandboxCommandCancelled,
	}); err != nil {
		t.Fatal(err)
	}
	acknowledged, err := controller.CancelCommand(ctx, sandbox.AccountID, sandbox.ID, command.ID)
	if err != nil || acknowledged.CancellationPending || acknowledged.ErrorCode != "cancelled_by_user" {
		t.Fatalf("acknowledgement=%+v error=%v", acknowledged, err)
	}
	if _, err := controller.Execute(ctx, sandbox.AccountID, sandbox.ID, CommandRequest{
		IdempotencyKey: uuid.NewString(), Arguments: []string{"/usr/bin/true"},
	}); err != nil {
		t.Fatalf("new command remained blocked after cleanup: %v", err)
	}
}

func TestSandboxUserCancellationPreservesFinishedResult(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Millisecond)
	backend := store.NewMemory(store.Config{})
	sandbox := createReadyTestSandbox(t, backend, now)
	controller := testSandboxController(backend, &now)
	command, err := controller.Execute(ctx, sandbox.AccountID, sandbox.ID, CommandRequest{
		IdempotencyKey: uuid.NewString(), Arguments: []string{"/usr/bin/true"},
	})
	if err != nil {
		t.Fatal(err)
	}
	exitCode := int32(0)
	output := "completed output"
	if _, err := backend.ApplySandboxCommandUpdate(ctx, store.SandboxCommandUpdate{
		CommandID: command.ID, SandboxID: sandbox.ID, Generation: sandbox.Generation, FencingToken: sandbox.FencingToken,
		State: store.SandboxCommandSucceeded, ExitCode: &exitCode, StandardOutput: &output, UpdatedAt: now.Add(time.Second),
	}); err != nil {
		t.Fatal(err)
	}
	result, err := controller.CancelCommand(ctx, sandbox.AccountID, sandbox.ID, command.ID)
	if err != nil || result.State != store.SandboxCommandSucceeded || result.StandardOutput != output || result.CancellationPending {
		t.Fatalf("finished result changed: %+v %v", result, err)
	}
}
