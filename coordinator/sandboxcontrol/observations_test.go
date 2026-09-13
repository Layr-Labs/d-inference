package sandboxcontrol

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/sandboxhost"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

func TestSandboxStoppedHeartbeatRejectsRetiredSessionAndAllowsRecovery(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Millisecond)
	backend := store.NewMemory(store.Config{})
	controller := testSandboxController(backend, &now)
	ready := createReadyTestSandbox(t, backend, now)
	old := registerStartTestHost(t, controller.hosts, ready, &cancellationTestTransport{}, true)
	controller.hosts.Disconnect(old)
	session := registerStartTestHost(t, controller.hosts, ready, &cancellationTestTransport{}, true)
	heartbeat := &protocol.SandboxHostHeartbeatPayload{Leases: []protocol.SandboxHostLeaseObservation{{
		Scope: protocol.SandboxScope{SandboxID: ready.ID, Generation: ready.Generation, FencingToken: ready.FencingToken}, State: protocol.SandboxOperationStopped,
		LeaseExpiresAt: ready.LeaseExpiresAt.Format(time.RFC3339Nano), Resources: protocol.SandboxResources{CPUCount: ready.CPUCount, MemoryBytes: ready.MemoryBytes,
			WorkspaceBytes: ready.WorkspaceBytes, CommandTimeoutSeconds: ready.CommandTimeoutSeconds, GPU: ready.GPU}}}}
	if err := controller.observeStoppedLeases(ctx, old, heartbeat); !errors.Is(err, sandboxhost.ErrSessionClosed) {
		t.Fatalf("retired connection observed stopped: %v", err)
	}
	if err := controller.handleHeartbeat(ctx, session, heartbeat); err != nil {
		t.Fatal(err)
	}
	stopped, err := backend.GetSandbox(ctx, ready.AccountID, ready.ID)
	if err != nil || stopped.State != store.SandboxStateStopped {
		t.Fatalf("ready was not demoted after observed VM stop: %+v %v", stopped, err)
	}
	heartbeat.Leases[0].State = protocol.SandboxOperationReady
	if err := controller.handleHeartbeat(ctx, session, heartbeat); err != nil {
		t.Fatal(err)
	}
	stopped, err = backend.GetSandbox(ctx, ready.AccountID, ready.ID)
	if err != nil || stopped.State != store.SandboxStateStopped {
		t.Fatalf("heartbeat promoted without start: %+v %v", stopped, err)
	}
	start, err := controller.Start(ctx, ready.AccountID, ready.ID, uuid.NewString())
	if err != nil {
		t.Fatalf("direct recovery start: %v", err)
	}
	heartbeat.Leases[0].State = protocol.SandboxOperationStopped
	if err := controller.handleHeartbeat(ctx, session, heartbeat); err != nil {
		t.Fatal(err)
	}
	preparing, err := backend.GetSandbox(ctx, ready.AccountID, ready.ID)
	if err != nil || preparing.State != store.SandboxStatePreparing {
		t.Fatalf("pending start demoted by old heartbeat: %+v %v", preparing, err)
	}
	if start.RequestedFencingToken <= ready.FencingToken {
		t.Fatal("recovery did not fence old commands")
	}
}
