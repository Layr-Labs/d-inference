package sandboxcontrol

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/sandboxhost"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestCommandCancellationRetriesAcrossSendFailureAndReconnect(t *testing.T) {
	ctx := context.Background()
	now := time.Date(2026, 8, 25, 15, 0, 0, 0, time.UTC)
	backend := store.NewMemory(store.Config{})
	sandbox := createReadyTestSandbox(t, backend, now)
	command := &store.SandboxCommand{
		ID:             "50000000-0000-0000-0000-000000000105",
		SandboxID:      sandbox.ID,
		AccountID:      sandbox.AccountID,
		IdempotencyKey: "60000000-0000-0000-0000-000000000106",
		Generation:     sandbox.Generation,
		FencingToken:   sandbox.FencingToken,
		Arguments:      []string{"/usr/bin/sleep", "900"},
		TimeoutSeconds: CommandTimeoutSeconds,
		State:          store.SandboxCommandPending,
		CreatedAt:      now,
		UpdatedAt:      now,
	}
	if _, created, err := backend.CreateSandboxCommand(ctx, command); err != nil ||
		!created {
		t.Fatalf("create command: created=%v error=%v", created, err)
	}
	timedOut, err := backend.ApplySandboxCommandUpdate(
		ctx,
		store.SandboxCommandUpdate{
			CommandID:           command.ID,
			SandboxID:           command.SandboxID,
			Generation:          command.Generation,
			FencingToken:        command.FencingToken,
			State:               store.SandboxCommandTimedOut,
			ErrorCode:           store.SandboxCommandDeadlineExceeded,
			RequestCancellation: true,
			UpdatedAt:           now.Add(time.Second),
		},
	)
	if err != nil {
		t.Fatalf("persist timeout cancellation: %v", err)
	}

	hosts := sandboxhost.NewRegistry(nil)
	currentTime := now.Add(2 * time.Second)
	controller := &Controller{
		store:           backend,
		hosts:           hosts,
		now:             func() time.Time { return currentTime },
		hostNextFence:   make(map[string]uint64),
		reconciledEpoch: make(map[string]string),
	}
	if err := controller.dispatchCommandCancellation(
		ctx,
		sandbox,
		timedOut,
	); !errors.Is(err, ErrHostUnavailable) {
		t.Fatalf("missing-session cancellation error = %v", err)
	}
	assertCancellationAttempt(t, backend, command, 1, "host_unavailable", true)

	failingTransport := &cancellationTestTransport{failuresRemaining: 1}
	failingSession := registerCancellationTestHost(
		t,
		hosts,
		sandbox,
		"70000000-0000-0000-0000-000000000107",
		failingTransport,
	)
	currentTime = now.Add(3 * time.Second)
	if err := controller.dispatchCommandCancellation(
		ctx,
		sandbox,
		timedOut,
	); err == nil {
		t.Fatal("transport failure unexpectedly delivered cancellation")
	}
	assertCancellationAttempt(t, backend, command, 2, "dispatch_failed", true)
	hosts.Disconnect(failingSession)

	successfulTransport := &cancellationTestTransport{}
	successfulSession := registerCancellationTestHost(
		t,
		hosts,
		sandbox,
		"80000000-0000-0000-0000-000000000108",
		successfulTransport,
	)
	currentTime = now.Add(4 * time.Second)
	if err := controller.reconcileHost(
		ctx,
		successfulSession,
		&protocol.SandboxHostHeartbeatPayload{},
	); err != nil {
		t.Fatalf("reconcile cancellation after reconnect: %v", err)
	}
	assertCancellationAttempt(t, backend, command, 3, "", true)
	frames := successfulTransport.frames()
	if len(frames) != 1 {
		t.Fatalf("delivered cancellation frames = %d, want 1", len(frames))
	}
	decoded, err := protocol.DecodeSandboxCoordinatorMessage(frames[0])
	if err != nil {
		t.Fatalf("decode cancellation frame: %v", err)
	}
	payload, ok := decoded.Payload.(*protocol.SandboxCommandControlPayload)
	if !ok ||
		decoded.Header.Type != protocol.SandboxTypeCancelCommand ||
		payload.OperationID != cancellationOperationID(command.ID) ||
		payload.CommandID != command.ID {
		t.Fatalf("cancellation frame = %#v", decoded)
	}

	currentTime = now.Add(5 * time.Second)
	if err := controller.handleCommandState(
		ctx,
		successfulSession,
		&protocol.SandboxCommandStatePayload{
			CommandID: command.ID,
			Scope: protocol.SandboxScope{
				SandboxID:    command.SandboxID,
				Generation:   command.Generation,
				FencingToken: command.FencingToken,
			},
			State: store.SandboxCommandCancelled,
		},
	); err != nil {
		t.Fatalf("acknowledge cancellation: %v", err)
	}
	assertCancellationAttempt(t, backend, command, 3, "", false)
	if err := controller.reconcileHost(
		ctx,
		successfulSession,
		&protocol.SandboxHostHeartbeatPayload{},
	); err != nil {
		t.Fatalf("reconcile acknowledged cancellation: %v", err)
	}
	if frames := successfulTransport.frames(); len(frames) != 1 {
		t.Fatalf("acknowledged cancellation was redelivered: %d frames", len(frames))
	}
}

func assertCancellationAttempt(
	t *testing.T,
	backend store.SandboxStore,
	command *store.SandboxCommand,
	attempts uint32,
	dispatchError string,
	pending bool,
) {
	t.Helper()
	stored, err := backend.GetSandboxCommand(
		context.Background(),
		command.AccountID,
		command.SandboxID,
		command.ID,
	)
	if err != nil {
		t.Fatalf("get cancellation state: %v", err)
	}
	if stored.CancelDispatchAttempts != attempts ||
		stored.LastCancelDispatchError != dispatchError ||
		stored.CancellationPending != pending {
		t.Fatalf(
			"cancellation state = attempts=%d error=%q pending=%v",
			stored.CancelDispatchAttempts,
			stored.LastCancelDispatchError,
			stored.CancellationPending,
		)
	}
}

func registerCancellationTestHost(
	t *testing.T,
	hosts *sandboxhost.Registry,
	sandbox *store.SandboxRecord,
	connectionEpoch string,
	transport sandboxhost.Transport,
) *sandboxhost.Session {
	t.Helper()
	session, err := hosts.Register(
		protocol.SandboxMessageHeader{
			Type:            protocol.SandboxTypeHostRegister,
			ProtocolVersion: protocol.SandboxProtocolVersion,
			HostID:          sandbox.HostID,
			ConnectionEpoch: connectionEpoch,
			Sequence:        1,
		},
		&protocol.SandboxHostRegisterPayload{
			Capabilities: protocol.SandboxHostCapabilities{
				DaemonVersion:       "0.1.0",
				OperatingSystem:     "macos",
				Architecture:        "arm64",
				MachineModel:        "Mac16,1",
				ChipName:            "Apple M4 Pro",
				CPUCount:            sandbox.CPUCount,
				MemoryBytes:         sandbox.MemoryBytes,
				MaximumSandboxes:    2,
				WorkspaceSizesBytes: []uint64{sandbox.WorkspaceBytes},
				BaseImageIDs:        []string{sandbox.BaseImageID},
			},
		},
		transport,
	)
	if err != nil {
		t.Fatalf("register cancellation test host: %v", err)
	}
	return session
}

type cancellationTestTransport struct {
	mu                sync.Mutex
	failuresRemaining int
	writes            [][]byte
}

func (t *cancellationTestTransport) Write(_ context.Context, frame []byte) error {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.failuresRemaining > 0 {
		t.failuresRemaining--
		return errors.New("injected cancellation transport failure")
	}
	t.writes = append(t.writes, append([]byte(nil), frame...))
	return nil
}

func (t *cancellationTestTransport) Close(string) error {
	return nil
}

func (t *cancellationTestTransport) frames() [][]byte {
	t.mu.Lock()
	defer t.mu.Unlock()
	frames := make([][]byte, len(t.writes))
	for index := range t.writes {
		frames[index] = append([]byte(nil), t.writes[index]...)
	}
	return frames
}
