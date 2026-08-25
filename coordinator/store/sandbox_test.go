package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestSandboxStoreFencedLifecycleAndCommandIdempotency(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Date(2026, 8, 24, 22, 0, 0, 0, time.UTC)
			sandboxID := "10000000-0000-0000-0000-000000000001"
			accountID := uniqueID("sandbox-account")
			hostID := "20000000-0000-0000-0000-000000000002"
			prepare := &SandboxOperation{
				ID:                      "30000000-0000-0000-0000-000000000003",
				SandboxID:               sandboxID,
				AccountID:               accountID,
				Kind:                    SandboxOperationKindPrepare,
				State:                   SandboxOperationPending,
				Generation:              1,
				FencingToken:            10,
				RequestedLeaseExpiresAt: now.Add(10 * time.Minute),
				CreatedAt:               now,
				UpdatedAt:               now,
			}
			sandbox := &SandboxRecord{
				ID:                    sandboxID,
				AccountID:             accountID,
				HostID:                hostID,
				Generation:            1,
				FencingToken:          10,
				BaseImageID:           "macos-tahoe-v1",
				CPUCount:              4,
				MemoryBytes:           8 << 30,
				WorkspaceBytes:        25 << 30,
				CommandTimeoutSeconds: 900,
				State:                 SandboxStatePreparing,
				LeaseExpiresAt:        now.Add(10 * time.Minute),
				CreatedAt:             now,
				UpdatedAt:             now,
			}
			if err := backend.CreateSandbox(ctx, sandbox, prepare); err != nil {
				t.Fatalf("create sandbox: %v", err)
			}
			if _, _, err := backend.ApplySandboxOperationUpdate(
				ctx,
				SandboxOperationUpdate{
					OperationID:  prepare.ID,
					SandboxID:    sandbox.ID,
					Generation:   1,
					FencingToken: 9,
					State:        SandboxOperationReady,
					UpdatedAt:    now.Add(time.Second),
				},
			); !errors.Is(err, ErrSandboxConflict) {
				t.Fatalf("stale prepare result error = %v", err)
			}
			ready, completedPrepare, err := backend.ApplySandboxOperationUpdate(
				ctx,
				SandboxOperationUpdate{
					OperationID:  prepare.ID,
					SandboxID:    sandbox.ID,
					Generation:   1,
					FencingToken: 10,
					State:        SandboxOperationReady,
					UpdatedAt:    now.Add(2 * time.Second),
				},
			)
			if err != nil {
				t.Fatalf("complete prepare: %v", err)
			}
			if ready.State != SandboxStateReady ||
				completedPrepare.State != SandboxOperationReady {
				t.Fatalf(
					"unexpected prepared state: sandbox=%s operation=%s",
					ready.State,
					completedPrepare.State,
				)
			}

			command := &SandboxCommand{
				ID:               "40000000-0000-0000-0000-000000000004",
				SandboxID:        sandbox.ID,
				AccountID:        accountID,
				IdempotencyKey:   "command-key",
				Generation:       1,
				FencingToken:     10,
				Arguments:        []string{"/usr/bin/printf", "hello"},
				Environment:      map[string]string{"LANG": "C"},
				WorkingDirectory: "/tmp",
				TimeoutSeconds:   900,
				State:            SandboxCommandPending,
				CreatedAt:        now.Add(3 * time.Second),
				UpdatedAt:        now.Add(3 * time.Second),
			}
			stored, created, err := backend.CreateSandboxCommand(ctx, command)
			if err != nil || !created || stored.ID != command.ID {
				t.Fatalf(
					"create command: stored=%+v created=%v err=%v",
					stored,
					created,
					err,
				)
			}
			retry := *command
			retry.ID = "50000000-0000-0000-0000-000000000005"
			stored, created, err = backend.CreateSandboxCommand(ctx, &retry)
			if err != nil || created || stored.ID != command.ID {
				t.Fatalf(
					"idempotent command: stored=%+v created=%v err=%v",
					stored,
					created,
					err,
				)
			}
			stdout := "hello"
			exitCode := int32(0)
			completedCommand, err := backend.ApplySandboxCommandUpdate(
				ctx,
				SandboxCommandUpdate{
					CommandID:      command.ID,
					SandboxID:      sandbox.ID,
					Generation:     1,
					FencingToken:   10,
					State:          SandboxCommandSucceeded,
					ExitCode:       &exitCode,
					StandardOutput: &stdout,
					UpdatedAt:      now.Add(4 * time.Second),
				},
			)
			if err != nil {
				t.Fatalf("complete command: %v", err)
			}
			if !completedCommand.Terminal() ||
				completedCommand.StandardOutput != "hello" ||
				completedCommand.CompletedAt == nil {
				t.Fatalf("unexpected completed command: %+v", completedCommand)
			}

			renew := &SandboxOperation{
				ID:                      "60000000-0000-0000-0000-000000000006",
				SandboxID:               sandbox.ID,
				AccountID:               accountID,
				Kind:                    SandboxOperationKindRenew,
				State:                   SandboxOperationPending,
				Generation:              1,
				FencingToken:            10,
				PreviousSandboxState:    SandboxStateReady,
				RequestedLeaseExpiresAt: now.Add(20 * time.Minute),
				CreatedAt:               now.Add(5 * time.Second),
				UpdatedAt:               now.Add(5 * time.Second),
			}
			if _, err := backend.BeginSandboxOperation(
				ctx,
				renew,
				SandboxStateReady,
			); err != nil {
				t.Fatalf("begin renewal: %v", err)
			}
			renewedExpiry := renew.RequestedLeaseExpiresAt
			renewed, _, err := backend.ApplySandboxOperationUpdate(
				ctx,
				SandboxOperationUpdate{
					OperationID:    renew.ID,
					SandboxID:      sandbox.ID,
					Generation:     1,
					FencingToken:   11,
					State:          SandboxOperationReady,
					LeaseExpiresAt: &renewedExpiry,
					UpdatedAt:      now.Add(6 * time.Second),
				},
			)
			if err != nil {
				t.Fatalf("complete renewal: %v", err)
			}
			if renewed.FencingToken != 11 ||
				!renewed.LeaseExpiresAt.Equal(renewedExpiry) {
				t.Fatalf("renewed sandbox = %+v", renewed)
			}
			if _, err := backend.GetSandbox(
				ctx,
				"another-account",
				sandbox.ID,
			); !errors.Is(err, ErrNotFound) {
				t.Fatalf("cross-account lookup error = %v", err)
			}
		})
	}
}
