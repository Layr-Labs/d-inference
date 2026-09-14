package store

import (
	"context"
	"testing"
	"time"
)

func TestSandboxCancellationDispatchClaimIsAtomicAcrossStores(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Date(2026, 8, 25, 21, 30, 0, 0, time.UTC)
			sandbox, command := createCancellationDispatchFixture(
				t,
				ctx,
				backend,
				now,
			)
			type claimResult struct {
				attempt uint32
				claimed bool
				err     error
			}
			start := make(chan struct{})
			results := make(chan claimResult, 2)
			for range 2 {
				go func() {
					<-start
					attempt, claimed, err :=
						backend.ClaimSandboxCommandCancellationDispatch(
							ctx,
							command.ID,
							0,
							now,
							now.Add(4*time.Second),
						)
					results <- claimResult{
						attempt: attempt,
						claimed: claimed,
						err:     err,
					}
				}()
			}
			close(start)

			claims := 0
			for range 2 {
				result := <-results
				if result.err != nil {
					t.Fatalf("concurrent claim: %v", result.err)
				}
				if result.claimed {
					claims++
					if result.attempt != 1 {
						t.Fatalf(
							"winning attempt = %d, want 1",
							result.attempt,
						)
					}
				} else if result.attempt != 0 {
					t.Fatalf(
						"losing attempt = %d, want 0",
						result.attempt,
					)
				}
			}
			if claims != 1 {
				t.Fatalf("concurrent successful claims = %d, want 1", claims)
			}
			stored, err := backend.GetSandboxCommand(
				ctx,
				command.AccountID,
				sandbox.ID,
				command.ID,
			)
			if err != nil {
				t.Fatalf("get atomically claimed command: %v", err)
			}
			if stored.CancelDispatchAttempts != 1 ||
				stored.LastCancelDispatchedAt == nil {
				t.Fatalf("atomically claimed command state = %+v", stored)
			}
		})
	}
}

func TestSandboxCancellationDispatchClaimCASAcrossStores(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Date(2026, 8, 25, 22, 0, 0, 0, time.UTC)
			sandbox, command := createCancellationDispatchFixture(
				t,
				ctx,
				backend,
				now,
			)
			claimedAt := now.Add(4 * time.Second)

			firstAttempt, claimed, err :=
				backend.ClaimSandboxCommandCancellationDispatch(
					ctx,
					command.ID,
					0,
					now,
					claimedAt,
				)
			if err != nil || !claimed || firstAttempt != 1 {
				t.Fatalf(
					"first claim: attempt=%d claimed=%v error=%v",
					firstAttempt,
					claimed,
					err,
				)
			}
			if attempt, claimed, err :=
				backend.ClaimSandboxCommandCancellationDispatch(
					ctx,
					command.ID,
					0,
					claimedAt,
					claimedAt,
				); err != nil || claimed || attempt != 0 {
				t.Fatalf(
					"stale claim: attempt=%d claimed=%v error=%v",
					attempt,
					claimed,
					err,
				)
			}

			if attempt, claimed, err :=
				backend.ClaimSandboxCommandCancellationDispatch(
					ctx,
					command.ID,
					firstAttempt,
					claimedAt.Add(-time.Second),
					claimedAt.Add(time.Second),
				); err != nil || claimed || attempt != 0 {
				t.Fatalf(
					"not-due claim: attempt=%d claimed=%v error=%v",
					attempt,
					claimed,
					err,
				)
			}

			secondClaimedAt := claimedAt.Add(time.Second)
			secondAttempt, claimed, err :=
				backend.ClaimSandboxCommandCancellationDispatch(
					ctx,
					command.ID,
					firstAttempt,
					claimedAt,
					secondClaimedAt,
				)
			if err != nil || !claimed || secondAttempt != 2 {
				t.Fatalf(
					"reconnect claim: attempt=%d claimed=%v error=%v",
					secondAttempt,
					claimed,
					err,
				)
			}
			if completed, err :=
				backend.CompleteSandboxCommandCancellationDispatch(
					ctx,
					command.ID,
					firstAttempt,
					"stale_failure",
				); err != nil || completed {
				t.Fatalf(
					"stale completion: completed=%v error=%v",
					completed,
					err,
				)
			}
			if completed, err :=
				backend.CompleteSandboxCommandCancellationDispatch(
					ctx,
					command.ID,
					secondAttempt,
					"dispatch_failed",
				); err != nil || !completed {
				t.Fatalf(
					"current completion: completed=%v error=%v",
					completed,
					err,
				)
			}

			stored, err := backend.GetSandboxCommand(
				ctx,
				command.AccountID,
				sandbox.ID,
				command.ID,
			)
			if err != nil {
				t.Fatalf("get claimed command: %v", err)
			}
			if stored.CancelDispatchAttempts != secondAttempt ||
				stored.LastCancelDispatchedAt == nil ||
				!stored.LastCancelDispatchedAt.Equal(secondClaimedAt) ||
				stored.LastCancelDispatchError != "dispatch_failed" {
				t.Fatalf("claimed command state = %+v", stored)
			}

			acknowledged, err := backend.ApplySandboxCommandUpdate(
				ctx,
				SandboxCommandUpdate{
					CommandID:    command.ID,
					SandboxID:    sandbox.ID,
					Generation:   command.Generation,
					FencingToken: command.FencingToken,
					State:        SandboxCommandCancelled,
					UpdatedAt:    now.Add(5 * time.Second),
				},
			)
			if err != nil || acknowledged.CancellationPending {
				t.Fatalf(
					"acknowledge cancellation: command=%+v error=%v",
					acknowledged,
					err,
				)
			}
			if completed, err :=
				backend.CompleteSandboxCommandCancellationDispatch(
					ctx,
					command.ID,
					secondAttempt,
					"late_failure",
				); err != nil || completed {
				t.Fatalf(
					"post-ack completion: completed=%v error=%v",
					completed,
					err,
				)
			}
		})
	}
}

func createCancellationDispatchFixture(
	t *testing.T,
	ctx context.Context,
	backend SandboxStore,
	now time.Time,
) (*SandboxRecord, *SandboxCommand) {
	t.Helper()
	sandbox, prepare := sandboxFencingFixture(
		"10000000-0000-0000-0000-000000000601",
		"20000000-0000-0000-0000-000000000602",
		"30000000-0000-0000-0000-000000000603",
		uniqueID("cancellation-dispatch-account"),
		"40000000-0000-0000-0000-000000000604",
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
		ID:             "50000000-0000-0000-0000-000000000605",
		SandboxID:      ready.ID,
		AccountID:      ready.AccountID,
		IdempotencyKey: "60000000-0000-0000-0000-000000000606",
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
	pending, err := backend.ApplySandboxCommandUpdate(
		ctx,
		SandboxCommandUpdate{
			CommandID:           command.ID,
			SandboxID:           command.SandboxID,
			Generation:          command.Generation,
			FencingToken:        command.FencingToken,
			State:               SandboxCommandTimedOut,
			ErrorCode:           SandboxCommandDeadlineExceeded,
			RequestCancellation: true,
			UpdatedAt:           now.Add(3 * time.Second),
		},
	)
	if err != nil {
		t.Fatalf("request cancellation: %v", err)
	}
	return ready, pending
}
