package sandboxhost

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

const (
	testConnectionEpoch = "00000000-0000-0000-0000-000000000002"
	testSandboxID       = "00000000-0000-0000-0000-000000000003"
)

func TestSessionEnforcesIdentityAndMonotonicSequence(t *testing.T) {
	now := time.Date(2026, 8, 24, 22, 0, 0, 0, time.UTC)
	registry := NewRegistry(nil)
	registry.now = func() time.Time { return now }
	session, err := registry.Register(
		testHeader(protocol.SandboxTypeHostRegister, 1),
		testRegistration(),
		&recordingTransport{},
	)
	if err != nil {
		t.Fatalf("register: %v", err)
	}
	heartbeat := &protocol.SandboxHostHeartbeatPayload{
		Mode:             "sandbox_dedicated",
		AvailableCPU:     8,
		AvailableMemory:  24 * 1024 * 1024 * 1024,
		NextFencingToken: 1,
		Leases:           []protocol.SandboxHostLeaseObservation{},
	}
	message := protocol.SandboxDecodedMessage{
		Header:  testHeader(protocol.SandboxTypeHostHeartbeat, 2),
		Payload: heartbeat,
	}
	if err := session.Handle(context.Background(), message); err != nil {
		t.Fatalf("handle heartbeat: %v", err)
	}
	snapshot := session.Snapshot()
	if snapshot.LastInbound != 2 ||
		!snapshot.LastHeartbeat.Equal(now) ||
		snapshot.Heartbeat == nil ||
		snapshot.Heartbeat.AvailableCPU != 8 {
		t.Fatalf("unexpected snapshot: %+v", snapshot)
	}

	if err := session.Handle(context.Background(), message); !errors.Is(
		err,
		ErrSequenceReplay,
	) {
		t.Fatalf("replayed sequence error = %v", err)
	}
	mismatched := message
	mismatched.Header.Sequence = 3
	mismatched.Header.ConnectionEpoch =
		"00000000-0000-0000-0000-000000000099"
	if err := session.Handle(context.Background(), mismatched); !errors.Is(
		err,
		ErrSessionMismatch,
	) {
		t.Fatalf("mismatched epoch error = %v", err)
	}
}

func TestSessionRejectsHeartbeatBeyondRegisteredCapacity(t *testing.T) {
	tests := map[string]func(*protocol.SandboxHostHeartbeatPayload){
		"available CPU": func(heartbeat *protocol.SandboxHostHeartbeatPayload) {
			heartbeat.AvailableCPU = 13
		},
		"available memory": func(heartbeat *protocol.SandboxHostHeartbeatPayload) {
			heartbeat.AvailableMemory = 49 * 1024 * 1024 * 1024
		},
		"aggregate CPU": func(heartbeat *protocol.SandboxHostHeartbeatPayload) {
			heartbeat.AvailableCPU = 10
			heartbeat.Leases = []protocol.SandboxHostLeaseObservation{
				testLeaseObservation(),
			}
		},
		"unsupported workspace": func(heartbeat *protocol.SandboxHostHeartbeatPayload) {
			lease := testLeaseObservation()
			lease.Resources.WorkspaceBytes = 50 * 1024 * 1024 * 1024
			heartbeat.Leases = []protocol.SandboxHostLeaseObservation{lease}
		},
	}
	for name, mutate := range tests {
		t.Run(name, func(t *testing.T) {
			registry := NewRegistry(nil)
			session, err := registry.Register(
				testHeader(protocol.SandboxTypeHostRegister, 1),
				testRegistration(),
				&recordingTransport{},
			)
			if err != nil {
				t.Fatalf("register: %v", err)
			}
			heartbeat := &protocol.SandboxHostHeartbeatPayload{
				Mode:             "sandbox_dedicated",
				AvailableCPU:     8,
				AvailableMemory:  24 * 1024 * 1024 * 1024,
				NextFencingToken: 2,
				Leases:           []protocol.SandboxHostLeaseObservation{},
			}
			mutate(heartbeat)
			err = session.Handle(
				context.Background(),
				protocol.SandboxDecodedMessage{
					Header:  testHeader(protocol.SandboxTypeHostHeartbeat, 2),
					Payload: heartbeat,
				},
			)
			if !errors.Is(err, ErrInvalidHeartbeat) {
				t.Fatalf("heartbeat error = %v", err)
			}
			snapshot := session.Snapshot()
			if snapshot.LastInbound != 1 || snapshot.Heartbeat != nil {
				t.Fatalf("invalid heartbeat changed session: %+v", snapshot)
			}
		})
	}
}

func TestRegisterReplacementIsIdentityBound(t *testing.T) {
	registry := NewRegistry(nil)
	firstTransport := &recordingTransport{}
	first, err := registry.Register(
		testHeader(protocol.SandboxTypeHostRegister, 1),
		testRegistration(),
		firstTransport,
	)
	if err != nil {
		t.Fatalf("register first: %v", err)
	}
	secondHeader := testHeader(protocol.SandboxTypeHostRegister, 1)
	secondHeader.ConnectionEpoch = "00000000-0000-0000-0000-000000000004"
	second, err := registry.Register(
		secondHeader,
		testRegistration(),
		&recordingTransport{},
	)
	if err != nil {
		t.Fatalf("register second: %v", err)
	}
	if firstTransport.closeCount() != 1 {
		t.Fatalf("replaced transport closes = %d", firstTransport.closeCount())
	}

	registry.Disconnect(first)
	current, ok := registry.Session(testHostID)
	if !ok || current != second {
		t.Fatal("old disconnect removed replacement session")
	}
	registry.Disconnect(second)
	if _, ok := registry.Session(testHostID); ok {
		t.Fatal("current disconnect retained session")
	}
	if _, err := registry.Register(
		testHeader(protocol.SandboxTypeHostRegister, 1),
		testRegistration(),
		&recordingTransport{},
	); !errors.Is(err, ErrEpochReused) {
		t.Fatalf("reused connection epoch error = %v", err)
	}
}

func TestReplacementCancelsSupersededMessageAuthority(t *testing.T) {
	handlerStarted := make(chan struct{})
	registry := NewRegistry(func(
		ctx context.Context,
		_ *Session,
		_ protocol.SandboxDecodedMessage,
	) error {
		close(handlerStarted)
		<-ctx.Done()
		return ctx.Err()
	})
	first, err := registry.Register(
		testHeader(protocol.SandboxTypeHostRegister, 1),
		testRegistration(),
		&recordingTransport{},
	)
	if err != nil {
		t.Fatalf("register first: %v", err)
	}
	result := make(chan error, 1)
	go func() {
		result <- first.Handle(
			context.Background(),
			protocol.SandboxDecodedMessage{
				Header: testHeader(protocol.SandboxTypeHostHeartbeat, 2),
				Payload: &protocol.SandboxHostHeartbeatPayload{
					Mode:             "sandbox_dedicated",
					NextFencingToken: 1,
					Leases:           []protocol.SandboxHostLeaseObservation{},
				},
			},
		)
	}()
	<-handlerStarted

	replacementHeader := testHeader(protocol.SandboxTypeHostRegister, 1)
	replacementHeader.ConnectionEpoch =
		"00000000-0000-0000-0000-000000000004"
	if _, err := registry.Register(
		replacementHeader,
		testRegistration(),
		&recordingTransport{},
	); err != nil {
		t.Fatalf("register replacement: %v", err)
	}
	select {
	case err := <-result:
		if !errors.Is(err, ErrSessionClosed) {
			t.Fatalf("superseded handler error = %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("superseded handler was not cancelled")
	}
}

func TestSessionSerializesOutboundSequence(t *testing.T) {
	registry := NewRegistry(nil)
	transport := &recordingTransport{}
	session, err := registry.Register(
		testHeader(protocol.SandboxTypeHostRegister, 1),
		testRegistration(),
		transport,
	)
	if err != nil {
		t.Fatalf("register: %v", err)
	}
	scope := protocol.SandboxScope{
		SandboxID:    testSandboxID,
		Generation:   1,
		FencingToken: 1,
	}
	if err := session.Send(
		context.Background(),
		protocol.SandboxTypeStop,
		protocol.SandboxOperationPayload{
			OperationID: "00000000-0000-0000-0000-000000000005",
			Scope:       scope,
		},
	); err != nil {
		t.Fatalf("send stop: %v", err)
	}
	if err := session.Send(
		context.Background(),
		protocol.SandboxTypeDelete,
		protocol.SandboxOperationPayload{
			OperationID: "00000000-0000-0000-0000-000000000006",
			Scope:       scope,
		},
	); err != nil {
		t.Fatalf("send delete: %v", err)
	}
	writes := transport.writesSnapshot()
	if len(writes) != 2 {
		t.Fatalf("writes = %d", len(writes))
	}
	for index, encoded := range writes {
		decoded, err := protocol.DecodeSandboxCoordinatorMessage(encoded)
		if err != nil {
			t.Fatalf("decode write %d: %v", index, err)
		}
		if decoded.Header.Sequence != uint64(index+1) {
			t.Fatalf(
				"write %d sequence = %d",
				index,
				decoded.Header.Sequence,
			)
		}
	}
}

func testHeader(
	messageType string,
	sequence uint64,
) protocol.SandboxMessageHeader {
	return protocol.SandboxMessageHeader{
		Type:            messageType,
		ProtocolVersion: protocol.SandboxProtocolVersion,
		HostID:          testHostID,
		ConnectionEpoch: testConnectionEpoch,
		Sequence:        sequence,
	}
}

func testRegistration() *protocol.SandboxHostRegisterPayload {
	return &protocol.SandboxHostRegisterPayload{
		Capabilities: protocol.SandboxHostCapabilities{
			DaemonVersion:       "0.1.0",
			OperatingSystem:     "macos",
			Architecture:        "arm64",
			MachineModel:        "Mac16,1",
			ChipName:            "Apple M4 Pro",
			CPUCount:            12,
			MemoryBytes:         48 * 1024 * 1024 * 1024,
			MaximumSandboxes:    2,
			WorkspaceSizesBytes: []uint64{25 * 1024 * 1024 * 1024},
			BaseImageIDs:        []string{"macos-tahoe-v1"},
			SupportsGPU:         true,
		},
	}
}

func testLeaseObservation() protocol.SandboxHostLeaseObservation {
	return protocol.SandboxHostLeaseObservation{
		Scope: protocol.SandboxScope{
			SandboxID:    testSandboxID,
			Generation:   1,
			FencingToken: 1,
		},
		State: protocol.SandboxOperationReady,
		Resources: protocol.SandboxResources{
			CPUCount:              4,
			MemoryBytes:           8 * 1024 * 1024 * 1024,
			WorkspaceBytes:        25 * 1024 * 1024 * 1024,
			CommandTimeoutSeconds: 900,
		},
		LeaseExpiresAt: "2026-08-24T23:00:00Z",
	}
}

type recordingTransport struct {
	mu      sync.Mutex
	writes  [][]byte
	closes  int
	reasons []string
}

func (t *recordingTransport) Write(_ context.Context, encoded []byte) error {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.writes = append(t.writes, append([]byte(nil), encoded...))
	return nil
}

func (t *recordingTransport) Close(reason string) error {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.closes++
	t.reasons = append(t.reasons, reason)
	return nil
}

func (t *recordingTransport) closeCount() int {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.closes
}

func (t *recordingTransport) writesSnapshot() [][]byte {
	t.mu.Lock()
	defer t.mu.Unlock()
	result := make([][]byte, len(t.writes))
	for index := range t.writes {
		result[index] = append([]byte(nil), t.writes[index]...)
	}
	return result
}
