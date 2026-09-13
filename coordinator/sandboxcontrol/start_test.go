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

func TestSandboxStartReplayReconnectAndStaleStop(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Millisecond)
	backend := store.NewMemory(store.Config{})
	controller := testSandboxController(backend, &now)
	stopped, stop := stoppedControllerSandbox(t, controller, backend, now)
	transport := &cancellationTestTransport{}
	session := registerStartTestHost(t, controller.hosts, stopped, transport, true)
	key := uuid.NewString()
	operation, err := controller.Start(ctx, stopped.AccountID, stopped.ID, key)
	if err != nil {
		t.Fatal(err)
	}
	first := decodeStartFrame(t, transport.frames())
	if first.Scope.FencingToken != stopped.FencingToken || first.RequestedFencingToken != operation.RequestedFencingToken || first.LeaseExpiresAt != stopped.LeaseExpiresAt.Format(time.RFC3339Nano) {
		t.Fatalf("start changed lease: %+v", first)
	}
	controller.hosts.Disconnect(session)
	replay, err := controller.Start(ctx, stopped.AccountID, stopped.ID, key)
	if err != nil || replay.ID != operation.ID || replay.RequestedFencingToken != operation.RequestedFencingToken {
		t.Fatalf("offline idempotency replay: %+v error=%v", replay, err)
	}
	transport = &cancellationTestTransport{}
	session = registerStartTestHost(t, controller.hosts, stopped, transport, true)
	if err := controller.reconcileHost(ctx, session, &protocol.SandboxHostHeartbeatPayload{}); err != nil {
		t.Fatal(err)
	}
	reconnected := decodeStartFrame(t, transport.frames())
	if *reconnected != *first {
		t.Fatalf("reconnect changed start identity: %+v %+v", first, reconnected)
	}
	observation := protocol.SandboxHostLeaseObservation{Scope: protocol.SandboxScope{SandboxID: stopped.ID, Generation: stopped.Generation, FencingToken: operation.RequestedFencingToken},
		State: protocol.SandboxOperationReady, LeaseExpiresAt: first.LeaseExpiresAt, Resources: protocol.SandboxResources{CPUCount: stopped.CPUCount,
			MemoryBytes: stopped.MemoryBytes, WorkspaceBytes: stopped.WorkspaceBytes, CommandTimeoutSeconds: stopped.CommandTimeoutSeconds, GPU: stopped.GPU}}
	pending := &store.PendingSandboxOperation{Sandbox: *stopped, Operation: *operation}
	if confirmed, err := controller.applyHeartbeatOperationObservation(ctx, pending, observation); err != nil || confirmed {
		t.Fatalf("ready heartbeat substituted for runtime start proof: confirmed=%v error=%v", confirmed, err)
	}
	payload := &protocol.SandboxOperationStatePayload{OperationID: operation.ID, Scope: observation.Scope, Operation: store.SandboxOperationKindStart, State: store.SandboxOperationBooting}
	if err := controller.handleOperationState(ctx, session, payload); err != nil {
		t.Fatal(err)
	}
	oldStop := &protocol.SandboxOperationStatePayload{OperationID: stop.ID, Scope: first.Scope, Operation: store.SandboxOperationKindStop, State: store.SandboxOperationStopped}
	if err := controller.handleOperationState(ctx, session, oldStop); !IsStaleHostResult(err) {
		t.Fatalf("old stop accepted after rotation: %v", err)
	}
	payload.State = store.SandboxOperationReady
	if err := controller.handleOperationState(ctx, session, payload); err != nil {
		t.Fatal(err)
	}
	ready, err := backend.GetSandbox(ctx, stopped.AccountID, stopped.ID)
	if err != nil || ready.State != store.SandboxStateReady || ready.FencingToken != first.RequestedFencingToken || !ready.LeaseExpiresAt.Equal(stopped.LeaseExpiresAt) {
		t.Fatalf("start result: %+v error=%v", ready, err)
	}
	if _, err := controller.Start(ctx, stopped.AccountID, stopped.ID, uuid.NewString()); !errors.Is(err, ErrSandboxNotReady) {
		t.Fatalf("second independent start admitted running guest: %v", err)
	}
}

func TestSandboxStartAdmissionAndCapabilityDowngrade(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Millisecond)
	backend := store.NewMemory(store.Config{})
	controller := testSandboxController(backend, &now)
	stopped, _ := stoppedControllerSandbox(t, controller, backend, now)
	if _, err := controller.Start(ctx, stopped.AccountID, stopped.ID, uuid.NewString()); !errors.Is(err, ErrHostUnavailable) {
		t.Fatalf("offline new start: %v", err)
	}
	oldHost := registerStartTestHost(t, controller.hosts, stopped, &cancellationTestTransport{}, false)
	if _, err := controller.Start(ctx, stopped.AccountID, stopped.ID, uuid.NewString()); !errors.Is(err, ErrStartUnavailable) {
		t.Fatalf("unsupported start: %v", err)
	}
	controller.hosts.Disconnect(oldHost)
	host := registerStartTestHost(t, controller.hosts, stopped, &cancellationTestTransport{}, true)
	if _, err := controller.Start(ctx, "other-account", stopped.ID, uuid.NewString()); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("cross-account start: %v", err)
	}
	key := uuid.NewString()
	operation, err := controller.Start(ctx, stopped.AccountID, stopped.ID, key)
	if err != nil {
		t.Fatal(err)
	}
	controller.hosts.Disconnect(host)
	transport := &cancellationTestTransport{}
	downgraded := registerStartTestHost(t, controller.hosts, stopped, transport, false)
	if err := controller.reconcileHost(ctx, downgraded, &protocol.SandboxHostHeartbeatPayload{}); err != nil {
		t.Fatal(err)
	}
	pending, err := backend.GetSandboxOperation(ctx, stopped.AccountID, operation.ID)
	if err != nil || pending.Terminal() || pending.RequestedFencingToken != operation.RequestedFencingToken || len(transport.frames()) != 0 {
		t.Fatalf("downgraded host lost uncertain start authority: %+v error=%v", pending, err)
	}
	if replay, err := controller.Start(ctx, stopped.AccountID, stopped.ID, key); err != nil || replay.Terminal() || replay.ID != operation.ID {
		t.Fatalf("uncertain replay lost idempotency: %+v error=%v", replay, err)
	}
	controller.hosts.Disconnect(downgraded)
	qualifiedTransport := &cancellationTestTransport{}
	qualified := registerStartTestHost(t, controller.hosts, stopped, qualifiedTransport, true)
	if err := controller.reconcileHost(ctx, qualified, &protocol.SandboxHostHeartbeatPayload{}); err != nil {
		t.Fatal(err)
	}
	if retried := decodeStartFrame(t, qualifiedTransport.frames()); retried.OperationID != operation.ID || retried.RequestedFencingToken != operation.RequestedFencingToken {
		t.Fatalf("qualified reconnect changed uncertain attempt: %+v", retried)
	}
	now = stopped.LeaseExpiresAt
	if _, err := controller.Start(ctx, stopped.AccountID, stopped.ID, uuid.NewString()); !errors.Is(err, ErrSandboxNotReady) {
		t.Fatalf("expired start: %v", err)
	}
}

func stoppedControllerSandbox(t *testing.T, controller *Controller, backend store.SandboxStore, now time.Time) (*store.SandboxRecord, *store.SandboxOperation) {
	t.Helper()
	ready := createReadyTestSandbox(t, backend, now)
	stop, err := controller.Stop(context.Background(), ready.AccountID, ready.ID, uuid.NewString())
	if err != nil {
		t.Fatal(err)
	}
	stopped, _, err := backend.ApplySandboxOperationUpdate(context.Background(), store.SandboxOperationUpdate{OperationID: stop.ID, SandboxID: ready.ID,
		Generation: ready.Generation, FencingToken: ready.FencingToken, State: store.SandboxOperationStopped, UpdatedAt: now})
	if err != nil {
		t.Fatal(err)
	}
	return stopped, stop
}

func registerStartTestHost(t *testing.T, registry *sandboxhost.Registry, sandbox *store.SandboxRecord, transport *cancellationTestTransport, supports bool) *sandboxhost.Session {
	t.Helper()
	session, err := registry.Register(protocol.SandboxMessageHeader{Type: protocol.SandboxTypeHostRegister, ProtocolVersion: protocol.SandboxProtocolVersion,
		HostID: sandbox.HostID, ConnectionEpoch: uuid.NewString(), Sequence: 1}, &protocol.SandboxHostRegisterPayload{Capabilities: protocol.SandboxHostCapabilities{
		DaemonVersion: "0.1.0", OperatingSystem: "macos", Architecture: "arm64", MachineModel: "Mac16,1", ChipName: "Apple M4 Pro",
		CPUCount: sandbox.CPUCount, MemoryBytes: sandbox.MemoryBytes, MaximumSandboxes: 2, WorkspaceSizesBytes: []uint64{sandbox.WorkspaceBytes},
		BaseImageIDs: []string{sandbox.BaseImageID}, SupportsStart: supports}}, transport)
	if err != nil {
		t.Fatal(err)
	}
	return session
}

func decodeStartFrame(t *testing.T, frames [][]byte) *protocol.SandboxStartPayload {
	t.Helper()
	if len(frames) != 1 {
		t.Fatalf("start frames=%d", len(frames))
	}
	decoded, err := protocol.DecodeSandboxCoordinatorMessage(frames[0])
	if err != nil {
		t.Fatal(err)
	}
	start, ok := decoded.Payload.(*protocol.SandboxStartPayload)
	if !ok {
		t.Fatalf("start payload type %T", decoded.Payload)
	}
	return start
}
