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

func TestRuntimeCleanupFailureRequiresCancellationProof(t *testing.T) {
	tests := []struct {
		name          string
		expectedState string
		report        func(
			context.Context,
			*Controller,
			*sandboxhost.Session,
			*store.SandboxCommand,
		) error
	}{
		{
			name:          "command state",
			expectedState: store.SandboxCommandFailed,
			report: func(
				ctx context.Context,
				controller *Controller,
				session *sandboxhost.Session,
				command *store.SandboxCommand,
			) error {
				exitCode := int32(-1)
				errorCode := "runtime_cleanup_failed"
				return controller.HandleHostMessage(
					ctx,
					session,
					protocol.SandboxDecodedMessage{
						Payload: &protocol.SandboxCommandStatePayload{
							CommandID: command.ID,
							Scope: protocol.SandboxScope{
								SandboxID:    command.SandboxID,
								Generation:   command.Generation,
								FencingToken: command.FencingToken,
							},
							State:     store.SandboxCommandFailed,
							ExitCode:  &exitCode,
							ErrorCode: &errorCode,
						},
					},
				)
			},
		},
		{
			name:          "command-scoped host failure",
			expectedState: store.SandboxCommandLost,
			report: func(
				ctx context.Context,
				controller *Controller,
				session *sandboxhost.Session,
				command *store.SandboxCommand,
			) error {
				commandID := command.ID
				scope := protocol.SandboxScope{
					SandboxID:    command.SandboxID,
					Generation:   command.Generation,
					FencingToken: command.FencingToken,
				}
				return controller.HandleHostMessage(
					ctx,
					session,
					protocol.SandboxDecodedMessage{
						Payload: &protocol.SandboxHostFailurePayload{
							CommandID: &commandID,
							Scope:     &scope,
							ErrorCode: "runtime_cleanup_failed",
						},
					},
				)
			},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			ctx := context.Background()
			baseTime := time.Date(2026, 8, 25, 19, 0, 0, 0, time.UTC)
			currentTime := baseTime.Add(2 * time.Second)
			backend := store.NewMemory(store.Config{})
			sandbox := createReadyTestSandbox(t, backend, baseTime)
			hosts := sandboxhost.NewRegistry(nil)
			transport := &cancellationTestTransport{}
			session := registerCancellationTestHost(
				t,
				hosts,
				sandbox,
				"a0000000-0000-0000-0000-000000000521",
				transport,
			)
			controller := &Controller{
				store:           backend,
				hosts:           hosts,
				now:             func() time.Time { return currentTime },
				hostNextFence:   make(map[string]uint64),
				reconciledEpoch: make(map[string]string),
			}
			command := &store.SandboxCommand{
				ID:             "b0000000-0000-0000-0000-000000000522",
				SandboxID:      sandbox.ID,
				AccountID:      sandbox.AccountID,
				IdempotencyKey: "c0000000-0000-0000-0000-000000000523",
				Generation:     sandbox.Generation,
				FencingToken:   sandbox.FencingToken,
				Arguments:      []string{"/usr/bin/sleep", "900"},
				TimeoutSeconds: CommandTimeoutSeconds,
				State:          store.SandboxCommandPending,
				CreatedAt:      baseTime,
				UpdatedAt:      baseTime,
			}
			if _, created, err := backend.CreateSandboxCommand(
				ctx,
				command,
			); err != nil || !created {
				t.Fatalf("create running command: created=%v error=%v", created, err)
			}
			runningCommand, err := backend.ApplySandboxCommandUpdate(
				ctx,
				store.SandboxCommandUpdate{
					CommandID:    command.ID,
					SandboxID:    command.SandboxID,
					Generation:   command.Generation,
					FencingToken: command.FencingToken,
					State:        store.SandboxCommandRunning,
					UpdatedAt:    baseTime.Add(time.Second),
				},
			)
			if err != nil {
				t.Fatalf("mark command running: %v", err)
			}
			command = runningCommand

			if err := test.report(ctx, controller, session, command); err != nil {
				t.Fatalf("report cleanup failure: %v", err)
			}
			stored, err := backend.GetSandboxCommand(
				ctx,
				command.AccountID,
				command.SandboxID,
				command.ID,
			)
			if err != nil {
				t.Fatalf("get failed command: %v", err)
			}
			if stored.State != test.expectedState ||
				stored.ErrorCode != "runtime_cleanup_failed" ||
				!stored.CancellationPending {
				t.Fatalf("cleanup failure released execution authority: %+v", stored)
			}
			if frames := transport.frames(); len(frames) != 1 {
				t.Fatalf("initial cancellation frames = %d, want 1", len(frames))
			}

			next := *command
			next.ID = "d0000000-0000-0000-0000-000000000524"
			next.IdempotencyKey = "e0000000-0000-0000-0000-000000000525"
			next.State = store.SandboxCommandPending
			next.StartedAt = nil
			next.CreatedAt = baseTime.Add(3 * time.Second)
			next.UpdatedAt = next.CreatedAt
			if _, _, err := backend.CreateSandboxCommand(
				ctx,
				&next,
			); !errors.Is(err, store.ErrSandboxConflict) {
				t.Fatalf("new command admitted without stop proof: %v", err)
			}

			firstDispatchAt := currentTime
			currentTime = firstDispatchAt.Add(
				dispatchRetryInterval - time.Nanosecond,
			)
			if err := test.report(ctx, controller, session, command); err != nil {
				t.Fatalf("repeat cleanup failure: %v", err)
			}
			if frames := transport.frames(); len(frames) != 1 {
				t.Fatalf("cancellation retried before interval: %d frames", len(frames))
			}
			currentTime = firstDispatchAt.Add(dispatchRetryInterval)
			if err := controller.sweepPendingCommandCancellations(ctx); err != nil {
				t.Fatalf("retry due cancellation: %v", err)
			}
			if frames := transport.frames(); len(frames) != 2 {
				t.Fatalf("due cancellation frames = %d, want 2", len(frames))
			}

			currentTime = currentTime.Add(time.Second)
			if err := controller.handleCommandState(
				ctx,
				session,
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
				t.Fatalf("record stopped proof: %v", err)
			}
			if _, created, err := backend.CreateSandboxCommand(
				ctx,
				&next,
			); err != nil || !created {
				t.Fatalf("new command after stop proof: created=%v error=%v", created, err)
			}
		})
	}
}
