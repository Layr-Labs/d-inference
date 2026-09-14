package sandboxcontrol

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/sandboxhost"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestCancellationFailureReportsRespectRetryInterval(t *testing.T) {
	tests := []struct {
		name      string
		reconcile bool
		report    func(
			context.Context,
			*Controller,
			*sandboxhost.Session,
			*store.SandboxCommand,
		) error
	}{
		{
			name: "command state",
			report: func(
				ctx context.Context,
				controller *Controller,
				session *sandboxhost.Session,
				command *store.SandboxCommand,
			) error {
				exitCode := int32(-1)
				errorCode := "operation_in_progress"
				return controller.handleCommandState(
					ctx,
					session,
					&protocol.SandboxCommandStatePayload{
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
				)
			},
		},
		{
			name:      "host failure",
			reconcile: true,
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
				return controller.handleHostFailure(
					ctx,
					session,
					&protocol.SandboxHostFailurePayload{
						CommandID: &commandID,
						Scope:     &scope,
						ErrorCode: "runtime_cleanup_failed",
					},
				)
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			ctx := context.Background()
			baseTime := time.Date(2026, 8, 25, 16, 0, 0, 0, time.UTC)
			currentTime := baseTime
			backend := store.NewMemory(store.Config{})
			sandbox := createReadyTestSandbox(t, backend, baseTime)
			hosts := sandboxhost.NewRegistry(nil)
			transport := &cancellationTestTransport{}
			session := registerCancellationTestHost(
				t,
				hosts,
				sandbox,
				"90000000-0000-0000-0000-000000000109",
				transport,
			)
			controller := &Controller{
				store:           backend,
				hosts:           hosts,
				now:             func() time.Time { return currentTime },
				hostNextFence:   make(map[string]uint64),
				reconciledEpoch: make(map[string]string),
			}
			if err := controller.reconcileHost(
				ctx,
				session,
				&protocol.SandboxHostHeartbeatPayload{},
			); err != nil {
				t.Fatalf("prime host reconciliation: %v", err)
			}

			command := &store.SandboxCommand{
				ID:             "a0000000-0000-0000-0000-000000000110",
				SandboxID:      sandbox.ID,
				AccountID:      sandbox.AccountID,
				IdempotencyKey: "b0000000-0000-0000-0000-000000000111",
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
					UpdatedAt:           baseTime.Add(time.Second),
				},
			)
			if err != nil {
				t.Fatalf("persist timeout cancellation: %v", err)
			}
			currentTime = baseTime.Add(2 * time.Second)
			if err := controller.dispatchCommandCancellation(
				ctx,
				sandbox,
				timedOut,
			); err != nil {
				t.Fatalf("deliver initial cancellation: %v", err)
			}
			assertCancellationAttempt(t, backend, command, 1, "", true)
			if frames := transport.frames(); len(frames) != 1 {
				t.Fatalf("initial cancellation frames = %d, want 1", len(frames))
			}
			firstDispatchAt := currentTime

			for duplicate := 0; duplicate < 2; duplicate++ {
				currentTime = baseTime.Add(
					time.Duration(duplicate+3) * time.Second,
				)
				if err := test.report(
					ctx,
					controller,
					session,
					command,
				); err != nil {
					t.Fatalf(
						"handle persistent cancellation failure %d: %v",
						duplicate+1,
						err,
					)
				}
			}
			assertCancellationAttempt(t, backend, command, 1, "", true)
			if frames := transport.frames(); len(frames) != 1 {
				t.Fatalf(
					"failure reports immediately redispatched %d frames",
					len(frames),
				)
			}

			retry := func() error {
				if test.reconcile {
					return controller.reconcileHost(
						ctx,
						session,
						&protocol.SandboxHostHeartbeatPayload{},
					)
				}
				return controller.sweepPendingCommandCancellations(ctx)
			}
			currentTime = firstDispatchAt.Add(
				dispatchRetryInterval - time.Nanosecond,
			)
			if err := retry(); err != nil {
				t.Fatalf("retry before interval: %v", err)
			}
			assertCancellationAttempt(t, backend, command, 1, "", true)

			currentTime = firstDispatchAt.Add(dispatchRetryInterval)
			if err := retry(); err != nil {
				t.Fatalf("retry at interval: %v", err)
			}
			assertCancellationAttempt(t, backend, command, 2, "", true)
			if frames := transport.frames(); len(frames) != 2 {
				t.Fatalf("due cancellation frames = %d, want 2", len(frames))
			}
			if err := retry(); err != nil {
				t.Fatalf("repeat retry at same time: %v", err)
			}
			assertCancellationAttempt(t, backend, command, 2, "", true)
			if frames := transport.frames(); len(frames) != 2 {
				t.Fatalf(
					"same-time retry redelivered cancellation: %d frames",
					len(frames),
				)
			}
		})
	}
}
