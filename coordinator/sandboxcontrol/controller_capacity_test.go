package sandboxcontrol

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/sandboxhost"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestSelectHostConservativelyAccountsMismatchedLease(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Millisecond)
	backend := store.NewMemory(store.Config{})
	sandbox := createReadyTestSandbox(t, backend, now)
	hosts := sandboxhost.NewRegistry(nil)
	session, err := hosts.Register(
		protocol.SandboxMessageHeader{
			Type:            protocol.SandboxTypeHostRegister,
			ProtocolVersion: protocol.SandboxProtocolVersion,
			HostID:          sandbox.HostID,
			ConnectionEpoch: "50000000-0000-0000-0000-000000000105",
			Sequence:        1,
		},
		&protocol.SandboxHostRegisterPayload{
			Capabilities: protocol.SandboxHostCapabilities{
				DaemonVersion:       "0.1.0",
				OperatingSystem:     "macos",
				Architecture:        "arm64",
				MachineModel:        "Mac16,1",
				ChipName:            "Apple M4 Pro",
				CPUCount:            8,
				MemoryBytes:         16 << 30,
				MaximumSandboxes:    2,
				WorkspaceSizesBytes: []uint64{25 << 30},
				BaseImageIDs:        []string{sandbox.BaseImageID},
			},
		},
		sandboxTestTransport{},
	)
	if err != nil {
		t.Fatalf("register host: %v", err)
	}
	heartbeat := &protocol.SandboxHostHeartbeatPayload{
		Mode:             "sandbox_dedicated",
		AvailableCPU:     7,
		AvailableMemory:  14 << 30,
		NextFencingToken: 11,
		Leases: []protocol.SandboxHostLeaseObservation{{
			Scope: protocol.SandboxScope{
				SandboxID:    sandbox.ID,
				Generation:   sandbox.Generation,
				FencingToken: sandbox.FencingToken,
			},
			State: protocol.SandboxOperationReady,
			Resources: protocol.SandboxResources{
				CPUCount:              1,
				MemoryBytes:           2 << 30,
				WorkspaceBytes:        sandbox.WorkspaceBytes,
				CommandTimeoutSeconds: sandbox.CommandTimeoutSeconds,
			},
			LeaseExpiresAt: sandbox.LeaseExpiresAt.Format(time.RFC3339Nano),
		}},
	}
	if err := session.Handle(
		context.Background(),
		protocol.SandboxDecodedMessage{
			Header: protocol.SandboxMessageHeader{
				Type:            protocol.SandboxTypeHostHeartbeat,
				ProtocolVersion: protocol.SandboxProtocolVersion,
				HostID:          sandbox.HostID,
				ConnectionEpoch: "50000000-0000-0000-0000-000000000105",
				Sequence:        2,
			},
			Payload: heartbeat,
		},
	); err != nil {
		t.Fatalf("record heartbeat: %v", err)
	}
	controller := &Controller{
		store:           backend,
		hosts:           hosts,
		now:             time.Now,
		hostNextFence:   make(map[string]uint64),
		reconciledEpoch: make(map[string]string),
	}
	_, _, err = controller.selectHostLocked(
		context.Background(),
		sandbox.BaseImageID,
		protocol.SandboxResources{
			CPUCount:              1,
			MemoryBytes:           2 << 30,
			WorkspaceBytes:        25 << 30,
			CommandTimeoutSeconds: CommandTimeoutSeconds,
		},
		time.Now().UTC(),
	)
	if !errors.Is(err, ErrNoCapacity) {
		t.Fatalf("mismatched lease allowed overcommit: %v", err)
	}
}

type sandboxTestTransport struct{}

func (sandboxTestTransport) Write(context.Context, []byte) error {
	return nil
}

func (sandboxTestTransport) Close(string) error {
	return nil
}
