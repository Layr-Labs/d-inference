package store

import (
	"context"
	"errors"
	"fmt"
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
			createKey := "30000000-0000-0000-0000-000000000030"
			prepare := &SandboxOperation{
				ID:                      "30000000-0000-0000-0000-000000000003",
				SandboxID:               sandboxID,
				AccountID:               accountID,
				IdempotencyKey:          createKey,
				Kind:                    SandboxOperationKindPrepare,
				State:                   SandboxOperationPending,
				Generation:              1,
				FencingToken:            10,
				RequestedLeaseExpiresAt: now.Add(30 * time.Minute),
				CreatedAt:               now,
				UpdatedAt:               now,
			}
			sandbox := &SandboxRecord{
				ID:                    sandboxID,
				AccountID:             accountID,
				IdempotencyKey:        createKey,
				HostID:                hostID,
				Generation:            1,
				FencingToken:          10,
				BaseImageID:           "macos-tahoe-v1",
				CPUCount:              4,
				MemoryBytes:           8 << 30,
				WorkspaceBytes:        25 << 30,
				CommandTimeoutSeconds: 900,
				State:                 SandboxStatePreparing,
				LeaseExpiresAt:        now.Add(30 * time.Minute),
				CreatedAt:             now,
				UpdatedAt:             now,
			}
			storedSandbox, storedPrepare, created, err := backend.CreateSandbox(
				ctx,
				sandbox,
				prepare,
				SandboxAllocationLimits{
					MaximumActive:     4,
					MaximumPerAccount: 2,
					MaximumPerHost:    2,
				},
			)
			if err != nil {
				t.Fatalf("create sandbox: %v", err)
			}
			if !created ||
				storedSandbox.ID != sandbox.ID ||
				storedPrepare.ID != prepare.ID {
				t.Fatalf(
					"unexpected create result: sandbox=%+v operation=%+v created=%v",
					storedSandbox,
					storedPrepare,
					created,
				)
			}
			retriedSandbox := *sandbox
			retriedSandbox.ID = "10000000-0000-0000-0000-000000000011"
			retriedPrepare := *prepare
			retriedPrepare.ID = "30000000-0000-0000-0000-000000000013"
			retriedPrepare.SandboxID = retriedSandbox.ID
			storedSandbox, storedPrepare, created, err = backend.CreateSandbox(
				ctx,
				&retriedSandbox,
				&retriedPrepare,
				SandboxAllocationLimits{
					MaximumActive:     4,
					MaximumPerAccount: 2,
					MaximumPerHost:    2,
				},
			)
			if err != nil ||
				created ||
				storedSandbox.ID != sandbox.ID ||
				storedPrepare.ID != prepare.ID {
				t.Fatalf(
					"idempotent create: sandbox=%+v operation=%+v created=%v err=%v",
					storedSandbox,
					storedPrepare,
					created,
					err,
				)
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
				IdempotencyKey:   "40000000-0000-0000-0000-000000000040",
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
			completedAt := *completedCommand.CompletedAt
			replayedCommand, err := backend.ApplySandboxCommandUpdate(
				ctx,
				SandboxCommandUpdate{
					CommandID:      command.ID,
					SandboxID:      sandbox.ID,
					Generation:     1,
					FencingToken:   10,
					State:          SandboxCommandSucceeded,
					ExitCode:       &exitCode,
					StandardOutput: &stdout,
					UpdatedAt:      now.Add(30 * time.Second),
				},
			)
			if err != nil ||
				replayedCommand.CompletedAt == nil ||
				!replayedCommand.CompletedAt.Equal(completedAt) {
				t.Fatalf(
					"terminal command replay changed result: command=%+v err=%v",
					replayedCommand,
					err,
				)
			}

			renew := &SandboxOperation{
				ID:                      "60000000-0000-0000-0000-000000000006",
				SandboxID:               sandbox.ID,
				AccountID:               accountID,
				IdempotencyKey:          "60000000-0000-0000-0000-000000000060",
				Kind:                    SandboxOperationKindRenew,
				State:                   SandboxOperationPending,
				Generation:              1,
				FencingToken:            10,
				PreviousSandboxState:    SandboxStateReady,
				RequestedLeaseExpiresAt: now.Add(60 * time.Minute),
				CreatedAt:               now.Add(5 * time.Second),
				UpdatedAt:               now.Add(5 * time.Second),
			}
			if _, _, created, err := backend.BeginSandboxOperation(
				ctx,
				renew,
				SandboxStateReady,
			); err != nil || !created {
				t.Fatalf("begin renewal: %v", err)
			}
			renewedExpiry := renew.RequestedLeaseExpiresAt
			if _, _, err := backend.ApplySandboxOperationUpdate(
				ctx,
				SandboxOperationUpdate{
					OperationID:    renew.ID,
					SandboxID:      sandbox.ID,
					Generation:     1,
					FencingToken:   10,
					State:          SandboxOperationReady,
					LeaseExpiresAt: &renewedExpiry,
					UpdatedAt:      now.Add(6 * time.Second),
				},
			); !errors.Is(err, ErrSandboxConflict) {
				t.Fatalf("renewal without fence advancement error = %v", err)
			}
			renewed, _, err := backend.ApplySandboxOperationUpdate(
				ctx,
				SandboxOperationUpdate{
					OperationID:    renew.ID,
					SandboxID:      sandbox.ID,
					Generation:     1,
					FencingToken:   11,
					State:          SandboxOperationReady,
					LeaseExpiresAt: &renewedExpiry,
					UpdatedAt:      now.Add(7 * time.Second),
				},
			)
			if err != nil {
				t.Fatalf("complete renewal: %v", err)
			}
			if renewed.FencingToken != 11 ||
				!renewed.LeaseExpiresAt.Equal(renewedExpiry) {
				t.Fatalf("renewed sandbox = %+v", renewed)
			}
			replayedRenewal, replayedOperation, err :=
				backend.ApplySandboxOperationUpdate(
					ctx,
					SandboxOperationUpdate{
						OperationID:    renew.ID,
						SandboxID:      sandbox.ID,
						Generation:     1,
						FencingToken:   11,
						State:          SandboxOperationReady,
						LeaseExpiresAt: &renewedExpiry,
						UpdatedAt:      now.Add(8 * time.Second),
					},
				)
			if err != nil ||
				replayedRenewal.FencingToken != 11 ||
				replayedOperation.State != SandboxOperationReady {
				t.Fatalf(
					"terminal renewal replay failed: sandbox=%+v operation=%+v err=%v",
					replayedRenewal,
					replayedOperation,
					err,
				)
			}
			terminationKey := "70000000-0000-0000-0000-000000000070"
			terminating, err := backend.MarkSandboxTerminationRequested(
				ctx,
				accountID,
				sandbox.ID,
				terminationKey,
				now.Add(9*time.Second),
			)
			if err != nil ||
				!terminating.TerminationRequested ||
				terminating.TerminationIdempotencyKey != terminationKey {
				t.Fatalf(
					"mark termination: sandbox=%+v err=%v",
					terminating,
					err,
				)
			}
			retriedCommand := *command
			retriedCommand.ID = "80000000-0000-0000-0000-000000000080"
			retriedCommand.Generation = terminating.Generation
			retriedCommand.FencingToken = terminating.FencingToken
			stored, created, err = backend.CreateSandboxCommand(
				ctx,
				&retriedCommand,
			)
			if err != nil || created || stored.ID != command.ID {
				t.Fatalf(
					"command retry after authority advance: command=%+v created=%v err=%v",
					stored,
					created,
					err,
				)
			}
			blockedRenewal := &SandboxOperation{
				ID:                      "90000000-0000-0000-0000-000000000090",
				SandboxID:               sandbox.ID,
				AccountID:               accountID,
				IdempotencyKey:          "90000000-0000-0000-0000-000000000091",
				Kind:                    SandboxOperationKindRenew,
				State:                   SandboxOperationPending,
				Generation:              terminating.Generation,
				FencingToken:            terminating.FencingToken,
				PreviousSandboxState:    terminating.State,
				RequestedLeaseExpiresAt: now.Add(90 * time.Minute),
				CreatedAt:               now.Add(10 * time.Second),
				UpdatedAt:               now.Add(10 * time.Second),
			}
			if _, _, _, err := backend.BeginSandboxOperation(
				ctx,
				blockedRenewal,
				terminating.State,
			); !errors.Is(err, ErrSandboxConflict) {
				t.Fatalf("renewal after termination intent error = %v", err)
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

func TestSandboxStoreEnforcesPerHostCapacity(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Date(2026, 8, 24, 22, 0, 0, 0, time.UTC)
			hostOne := "a0000000-0000-0000-0000-000000000001"
			hostTwo := "a0000000-0000-0000-0000-000000000002"
			limits := SandboxAllocationLimits{
				MaximumActive:     10,
				MaximumPerAccount: 10,
				MaximumPerHost:    2,
			}
			create := func(index int, hostID string) error {
				sandboxID := fmt.Sprintf(
					"b0000000-0000-0000-0000-%012d",
					index,
				)
				idempotencyKey := fmt.Sprintf(
					"c0000000-0000-0000-0000-%012d",
					index,
				)
				operationID := fmt.Sprintf(
					"d0000000-0000-0000-0000-%012d",
					index,
				)
				sandbox := &SandboxRecord{
					ID:                    sandboxID,
					AccountID:             uniqueID("sandbox-capacity-account"),
					IdempotencyKey:        idempotencyKey,
					HostID:                hostID,
					Generation:            1,
					FencingToken:          uint64(index),
					BaseImageID:           "macos-tahoe-v1",
					CPUCount:              2,
					MemoryBytes:           4 << 30,
					WorkspaceBytes:        25 << 30,
					CommandTimeoutSeconds: 900,
					State:                 SandboxStatePreparing,
					LeaseExpiresAt:        now.Add(30 * time.Minute),
					CreatedAt:             now.Add(time.Duration(index) * time.Second),
					UpdatedAt:             now.Add(time.Duration(index) * time.Second),
				}
				operation := &SandboxOperation{
					ID:                      operationID,
					SandboxID:               sandboxID,
					AccountID:               sandbox.AccountID,
					IdempotencyKey:          idempotencyKey,
					Kind:                    SandboxOperationKindPrepare,
					State:                   SandboxOperationPending,
					Generation:              1,
					FencingToken:            uint64(index),
					RequestedLeaseExpiresAt: sandbox.LeaseExpiresAt,
					CreatedAt:               sandbox.CreatedAt,
					UpdatedAt:               sandbox.UpdatedAt,
				}
				_, _, _, err := backend.CreateSandbox(
					ctx,
					sandbox,
					operation,
					limits,
				)
				return err
			}

			if err := create(1, hostOne); err != nil {
				t.Fatalf("first host allocation: %v", err)
			}
			if err := create(2, hostOne); err != nil {
				t.Fatalf("second host allocation: %v", err)
			}
			if err := create(3, hostOne); !errors.Is(err, ErrSandboxCapacity) {
				t.Fatalf("third host allocation error = %v", err)
			}
			if err := create(4, hostTwo); err != nil {
				t.Fatalf("other host allocation: %v", err)
			}
		})
	}
}
