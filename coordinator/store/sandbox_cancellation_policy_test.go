package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestSandboxCancellationAcknowledgementBlocksNewWork(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Date(2026, 8, 25, 17, 0, 0, 0, time.UTC)
			sandbox, prepare := sandboxFencingFixture(
				"10000000-0000-0000-0000-000000000431",
				"20000000-0000-0000-0000-000000000432",
				"30000000-0000-0000-0000-000000000433",
				uniqueID("cancellation-admission-account"),
				"40000000-0000-0000-0000-000000000434",
				1,
				now,
			)
			stored, storedPrepare, _, err := backend.CreateSandbox(
				ctx,
				sandbox,
				prepare,
				SandboxAllocationLimits{
					MaximumActive:     2,
					MaximumPerAccount: 2,
					MaximumPerHost:    2,
				},
			)
			if err != nil {
				t.Fatalf("create sandbox: %v", err)
			}
			ready, _, err := backend.ApplySandboxOperationUpdate(
				ctx,
				SandboxOperationUpdate{
					OperationID:  storedPrepare.ID,
					SandboxID:    stored.ID,
					Generation:   stored.Generation,
					FencingToken: stored.FencingToken,
					State:        SandboxOperationReady,
					UpdatedAt:    now.Add(time.Second),
				},
			)
			if err != nil {
				t.Fatalf("complete prepare: %v", err)
			}
			command := &SandboxCommand{
				ID:             "50000000-0000-0000-0000-000000000435",
				SandboxID:      ready.ID,
				AccountID:      ready.AccountID,
				IdempotencyKey: "60000000-0000-0000-0000-000000000436",
				Generation:     ready.Generation,
				FencingToken:   ready.FencingToken,
				Arguments:      []string{"/usr/bin/sleep", "1"},
				TimeoutSeconds: 1,
				State:          SandboxCommandPending,
				CreatedAt:      now.Add(2 * time.Second),
				UpdatedAt:      now.Add(2 * time.Second),
			}
			if _, created, err := backend.CreateSandboxCommand(
				ctx,
				command,
			); err != nil || !created {
				t.Fatalf("create command: created=%v error=%v", created, err)
			}
			timedOut, err := backend.ApplySandboxCommandUpdate(
				ctx,
				SandboxCommandUpdate{
					CommandID:           command.ID,
					SandboxID:           command.SandboxID,
					Generation:          command.Generation,
					FencingToken:        command.FencingToken,
					State:               SandboxCommandTimedOut,
					ErrorCode:           SandboxCommandDeadlineExceeded,
					RequestCancellation: true,
					UpdatedAt:           command.Deadline(),
				},
			)
			if err != nil || !timedOut.CancellationPending {
				t.Fatalf("persist timeout cancellation: command=%+v error=%v", timedOut, err)
			}

			nextCommand := *command
			nextCommand.ID = "70000000-0000-0000-0000-000000000437"
			nextCommand.IdempotencyKey = "80000000-0000-0000-0000-000000000438"
			nextCommand.CreatedAt = now.Add(4 * time.Second)
			nextCommand.UpdatedAt = nextCommand.CreatedAt
			if _, _, err := backend.CreateSandboxCommand(
				ctx,
				&nextCommand,
			); !errors.Is(err, ErrSandboxConflict) {
				t.Fatalf("new command admitted before cancellation acknowledgement: %v", err)
			}
			renewal := &SandboxOperation{
				ID:                      "90000000-0000-0000-0000-000000000439",
				SandboxID:               ready.ID,
				AccountID:               ready.AccountID,
				IdempotencyKey:          "a0000000-0000-0000-0000-000000000440",
				Kind:                    SandboxOperationKindRenew,
				State:                   SandboxOperationPending,
				Generation:              ready.Generation,
				FencingToken:            ready.FencingToken,
				RequestedFencingToken:   ready.FencingToken + 1,
				PreviousSandboxState:    SandboxStateReady,
				RequestedLeaseExpiresAt: ready.LeaseExpiresAt.Add(30 * time.Minute),
				CreatedAt:               now.Add(4 * time.Second),
				UpdatedAt:               now.Add(4 * time.Second),
			}
			if _, _, _, err := backend.BeginSandboxOperation(
				ctx,
				renewal,
				SandboxStateReady,
			); !errors.Is(err, ErrSandboxConflict) {
				t.Fatalf("renewal admitted before cancellation acknowledgement: %v", err)
			}
			active, err := backend.ListActiveSandboxCommands(ctx, ready.ID)
			if err != nil || len(active) != 1 || active[0].ID != command.ID {
				t.Fatalf("blocking cancellation commands = %+v error=%v", active, err)
			}

			acknowledged, err := backend.ApplySandboxCommandUpdate(
				ctx,
				SandboxCommandUpdate{
					CommandID:    command.ID,
					SandboxID:    command.SandboxID,
					Generation:   command.Generation,
					FencingToken: command.FencingToken,
					State:        SandboxCommandCancelled,
					UpdatedAt:    now.Add(5 * time.Second),
				},
			)
			if err != nil || acknowledged.CancellationPending {
				t.Fatalf("acknowledge cancellation: command=%+v error=%v", acknowledged, err)
			}
			active, err = backend.ListActiveSandboxCommands(ctx, ready.ID)
			if err != nil || len(active) != 0 {
				t.Fatalf("active commands after acknowledgement = %+v error=%v", active, err)
			}
			if _, storedRenewal, created, err := backend.BeginSandboxOperation(
				ctx,
				renewal,
				SandboxStateReady,
			); err != nil || !created ||
				storedRenewal.Kind != SandboxOperationKindRenew {
				t.Fatalf(
					"renew after acknowledgement: operation=%+v created=%v error=%v",
					storedRenewal,
					created,
					err,
				)
			}
		})
	}
}
