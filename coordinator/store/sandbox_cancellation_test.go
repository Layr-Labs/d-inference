package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestSandboxTerminationQueuesUntilCommandCancellationAcknowledged(
	t *testing.T,
) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Date(2026, 8, 25, 14, 0, 0, 0, time.UTC)
			sandbox, prepare := sandboxFencingFixture(
				"10000000-0000-0000-0000-000000000401",
				"20000000-0000-0000-0000-000000000402",
				"30000000-0000-0000-0000-000000000403",
				uniqueID("queued-termination-account"),
				"40000000-0000-0000-0000-000000000404",
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
				ID:             "50000000-0000-0000-0000-000000000405",
				SandboxID:      ready.ID,
				AccountID:      ready.AccountID,
				IdempotencyKey: "60000000-0000-0000-0000-000000000406",
				Generation:     ready.Generation,
				FencingToken:   ready.FencingToken,
				Arguments:      []string{"/usr/bin/sleep", "900"},
				TimeoutSeconds: 900,
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
			terminationKey := "70000000-0000-0000-0000-000000000407"
			terminating, err := backend.MarkSandboxTerminationRequested(
				ctx,
				ready.AccountID,
				ready.ID,
				terminationKey,
				now.Add(3*time.Second),
			)
			if err != nil {
				t.Fatalf("mark termination: %v", err)
			}
			stop := &SandboxOperation{
				ID:                   "80000000-0000-0000-0000-000000000408",
				SandboxID:            ready.ID,
				AccountID:            ready.AccountID,
				IdempotencyKey:       "90000000-0000-0000-0000-000000000409",
				Kind:                 SandboxOperationKindStop,
				State:                SandboxOperationPending,
				Generation:           ready.Generation,
				FencingToken:         ready.FencingToken,
				PreviousSandboxState: SandboxStateReady,
				DeleteAfterStop:      true,
				CreatedAt:            now.Add(3 * time.Second),
				UpdatedAt:            now.Add(3 * time.Second),
			}
			unchanged, queued, created, err := backend.BeginSandboxOperation(
				ctx,
				stop,
				SandboxStateStopping,
			)
			if err != nil || !created {
				t.Fatalf("queue stop: created=%v error=%v", created, err)
			}
			if unchanged.State != SandboxStateReady ||
				queued.State != SandboxOperationQueued {
				t.Fatalf("queued termination = sandbox=%+v operation=%+v", unchanged, queued)
			}
			persisted, err := backend.GetSandboxCommand(
				ctx,
				command.AccountID,
				command.SandboxID,
				command.ID,
			)
			if err != nil || !persisted.CancellationPending {
				t.Fatalf("queued cancellation = command=%+v error=%v", persisted, err)
			}
			if _, _, activated, err := backend.ActivateQueuedSandboxOperation(
				ctx,
				queued.ID,
				now.Add(4*time.Second),
			); err != nil || activated {
				t.Fatalf("activated before cancellation acknowledgement: %v %v", activated, err)
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
					UpdatedAt:           now.Add(5 * time.Second),
				},
			)
			if err != nil || !timedOut.CancellationPending {
				t.Fatalf("persist timeout cancellation: command=%+v error=%v", timedOut, err)
			}
			if _, _, activated, err := backend.ActivateQueuedSandboxOperation(
				ctx,
				queued.ID,
				now.Add(6*time.Second),
			); err != nil || activated {
				t.Fatalf("activated before host acknowledgement: %v %v", activated, err)
			}
			type acknowledgementResult struct {
				command *SandboxCommand
				err     error
			}
			type activationResult struct {
				sandbox   *SandboxRecord
				operation *SandboxOperation
				activated bool
				err       error
			}
			start := make(chan struct{})
			acknowledgedResult := make(chan acknowledgementResult, 1)
			activatedResult := make(chan activationResult, 1)
			go func() {
				<-start
				acknowledged, updateErr := backend.ApplySandboxCommandUpdate(
					ctx,
					SandboxCommandUpdate{
						CommandID:    command.ID,
						SandboxID:    command.SandboxID,
						Generation:   command.Generation,
						FencingToken: command.FencingToken,
						State:        SandboxCommandCancelled,
						UpdatedAt:    now.Add(7 * time.Second),
					},
				)
				acknowledgedResult <- acknowledgementResult{
					command: acknowledged,
					err:     updateErr,
				}
			}()
			go func() {
				<-start
				stopping, activatedStop, activated, activateErr :=
					backend.ActivateQueuedSandboxOperation(
						ctx,
						queued.ID,
						now.Add(8*time.Second),
					)
				activatedResult <- activationResult{
					sandbox:   stopping,
					operation: activatedStop,
					activated: activated,
					err:       activateErr,
				}
			}()
			close(start)
			acknowledged := <-acknowledgedResult
			activation := <-activatedResult
			if acknowledged.err != nil ||
				acknowledged.command.CancellationPending {
				t.Fatalf(
					"acknowledge cancellation: command=%+v error=%v",
					acknowledged.command,
					acknowledged.err,
				)
			}
			if activation.err != nil {
				t.Fatalf("race queued stop activation: %v", activation.err)
			}
			stopping := activation.sandbox
			activatedStop := activation.operation
			activated := activation.activated
			if !activated {
				stopping, activatedStop, activated, err =
					backend.ActivateQueuedSandboxOperation(
						ctx,
						queued.ID,
						now.Add(9*time.Second),
					)
			}
			if err != nil || !activated ||
				stopping.State != SandboxStateStopping ||
				activatedStop.State != SandboxOperationPending {
				t.Fatalf(
					"activate queued stop: sandbox=%+v operation=%+v activated=%v error=%v",
					stopping,
					activatedStop,
					activated,
					err,
				)
			}
			if _, _, err := backend.CreateSandboxCommand(
				ctx,
				&SandboxCommand{
					ID:             "a0000000-0000-0000-0000-000000000410",
					SandboxID:      stopping.ID,
					AccountID:      stopping.AccountID,
					IdempotencyKey: "b0000000-0000-0000-0000-000000000411",
					Generation:     stopping.Generation,
					FencingToken:   stopping.FencingToken,
					Arguments:      []string{"/usr/bin/true"},
					TimeoutSeconds: 1,
					State:          SandboxCommandPending,
					CreatedAt:      now.Add(10 * time.Second),
					UpdatedAt:      now.Add(10 * time.Second),
				},
			); !errors.Is(err, ErrSandboxConflict) {
				t.Fatalf("command admitted during activated stop: %v", err)
			}
			if !terminating.TerminationRequested {
				t.Fatal("termination intent was not persisted")
			}
		})
	}
}

func TestSandboxCommandCreateRejectsCancellationDeliveryState(t *testing.T) {
	now := time.Date(2026, 8, 25, 16, 0, 0, 0, time.UTC)
	base := SandboxCommand{
		ID:             "10000000-0000-0000-0000-000000000421",
		SandboxID:      "20000000-0000-0000-0000-000000000422",
		AccountID:      "account",
		IdempotencyKey: "30000000-0000-0000-0000-000000000423",
		Generation:     1,
		FencingToken:   1,
		Arguments:      []string{"/usr/bin/true"},
		TimeoutSeconds: 1,
		State:          SandboxCommandPending,
		CreatedAt:      now,
		UpdatedAt:      now,
	}
	tests := map[string]func(*SandboxCommand){
		"pending": func(command *SandboxCommand) {
			command.CancellationPending = true
		},
		"attempts": func(command *SandboxCommand) {
			command.CancelDispatchAttempts = 1
		},
		"last attempt": func(command *SandboxCommand) {
			command.LastCancelDispatchedAt = &now
		},
		"last error": func(command *SandboxCommand) {
			command.LastCancelDispatchError = "host_unavailable"
		},
	}
	for name, mutate := range tests {
		t.Run(name, func(t *testing.T) {
			command := base
			mutate(&command)
			if err := validateSandboxCommandCreate(&command); !errors.Is(
				err,
				ErrSandboxInvalidTransition,
			) {
				t.Fatalf("create validation error = %v", err)
			}
		})
	}
}
