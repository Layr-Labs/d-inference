package sandboxcontrol

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

func TestSandboxIssuedLeasePrecisionSurvivesHostObservationAndStart(t *testing.T) {
	ctx := context.Background()
	// Use a real epoch with intentional sub-millisecond clock precision. The
	// Swift ISO8601DateFormatter heartbeat emits exactly milliseconds.
	now := time.Now().UTC().Truncate(time.Second).Add(123456789 * time.Nanosecond)
	backend := store.NewMemory(store.Config{})
	controller := testSandboxController(backend, &now)
	host := &store.SandboxRecord{HostID: uuid.NewString(), CPUCount: 8, MemoryBytes: 16 << 30, WorkspaceBytes: 25 << 30, BaseImageID: "macos-tahoe-v1"}
	transport := &cancellationTestTransport{}
	session := registerStartTestHost(t, controller.hosts, host, transport, true)
	if err := session.Handle(ctx, protocol.SandboxDecodedMessage{Header: protocol.SandboxMessageHeader{Type: protocol.SandboxTypeHostHeartbeat,
		ProtocolVersion: protocol.SandboxProtocolVersion, HostID: host.HostID, ConnectionEpoch: session.Snapshot().ConnectionEpoch, Sequence: 2},
		Payload: &protocol.SandboxHostHeartbeatPayload{Mode: "sandbox_dedicated", AvailableCPU: 8, AvailableMemory: 16 << 30, NextFencingToken: 10}}); err != nil {
		t.Fatal(err)
	}
	created, prepare, err := controller.Create(ctx, "precision-account", "test-key", CreateRequest{IdempotencyKey: uuid.NewString(), BaseImageID: host.BaseImageID,
		CPUCount: 4, MemoryBytes: 8 << 30, WorkspaceBytes: 25 << 30})
	if err != nil {
		t.Fatal(err)
	}
	assertIssuedLeasePrecision(t, created.LeaseExpiresAt, now)
	if err := controller.handleOperationState(ctx, session, &protocol.SandboxOperationStatePayload{OperationID: prepare.ID, Scope: sandboxScope(created),
		Operation: store.SandboxOperationKindPrepare, State: store.SandboxOperationReady}); err != nil {
		t.Fatal(err)
	}
	now = now.Add(time.Minute + 777777*time.Nanosecond)
	renewal, err := controller.Renew(ctx, created.AccountID, created.ID, uuid.NewString())
	if err != nil {
		t.Fatal(err)
	}
	assertIssuedLeasePrecision(t, renewal.RequestedLeaseExpiresAt, now)
	scope := sandboxScope(created)
	scope.FencingToken = renewal.RequestedFencingToken
	if err := controller.handleOperationState(ctx, session, &protocol.SandboxOperationStatePayload{OperationID: renewal.ID, Scope: scope,
		Operation: store.SandboxOperationKindRenew, State: store.SandboxOperationReady}); err != nil {
		t.Fatal(err)
	}
	const swiftTimestamp = "2006-01-02T15:04:05.000Z"
	expiry := renewal.RequestedLeaseExpiresAt.Format(swiftTimestamp)
	if err := controller.observeStoppedLeases(ctx, session, &protocol.SandboxHostHeartbeatPayload{Leases: []protocol.SandboxHostLeaseObservation{{
		Scope: scope, State: protocol.SandboxOperationStopped, LeaseExpiresAt: expiry, Resources: protocol.SandboxResources{CPUCount: created.CPUCount,
			MemoryBytes: created.MemoryBytes, WorkspaceBytes: created.WorkspaceBytes, CommandTimeoutSeconds: created.CommandTimeoutSeconds, GPU: created.GPU}}}}); err != nil {
		t.Fatal(err)
	}
	stopped, err := backend.GetSandbox(ctx, created.AccountID, created.ID)
	if err != nil || stopped.State != store.SandboxStateStopped {
		t.Fatalf("millisecond host observation rejected issued lease: %+v error=%v", stopped, err)
	}
	if _, err := controller.Start(ctx, created.AccountID, created.ID, uuid.NewString()); err != nil {
		t.Fatal(err)
	}
	frames := transport.frames()
	start := decodeStartFrame(t, frames[len(frames)-1:])
	parsed, err := time.Parse(time.RFC3339Nano, start.LeaseExpiresAt)
	if err != nil || parsed.Format(swiftTimestamp) != expiry || !parsed.Equal(stopped.LeaseExpiresAt) {
		t.Fatalf("start changed exact host expiry: %s vs %s error=%v", start.LeaseExpiresAt, expiry, err)
	}
}

func assertIssuedLeasePrecision(t *testing.T, expiry, acceptedAt time.Time) {
	t.Helper()
	expected := acceptedAt.UTC().Truncate(time.Millisecond).Add(LeaseDuration)
	if !expiry.Equal(expected) || expiry.Nanosecond()%int(time.Millisecond) != 0 {
		t.Fatalf("issued lease cannot roundtrip host milliseconds: got=%s want=%s", expiry.Format(time.RFC3339Nano), expected.Format(time.RFC3339Nano))
	}
}
