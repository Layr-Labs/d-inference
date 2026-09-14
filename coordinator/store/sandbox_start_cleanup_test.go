package store

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestSandboxStartCleanupFailureNeverReportsStopped(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			for _, rotated := range []bool{false, true} {
				ctx := context.Background()
				now := time.Now().UTC().Truncate(time.Millisecond)
				stopped, _ := stopSandboxForStart(t, backend, retentionSandbox(t, backend, now), now)
				_, start, _, err := backend.BeginSandboxOperation(ctx, sandboxStartTestOperation(stopped, now), SandboxStatePreparing)
				if err != nil {
					t.Fatal(err)
				}
				fence := stopped.FencingToken
				if rotated {
					fence = start.RequestedFencingToken
				}
				failed, _, err := backend.ApplySandboxOperationUpdate(ctx, SandboxOperationUpdate{OperationID: start.ID, SandboxID: stopped.ID,
					Generation: stopped.Generation, FencingToken: fence, State: SandboxOperationFailed, ErrorCode: SandboxRuntimeCleanupFailed, UpdatedAt: now})
				if err != nil || failed.State != SandboxStateFailed || failed.FencingToken != fence || !failed.ConsumesCapacity() || !failed.LeaseExpiresAt.Equal(stopped.LeaseExpiresAt) {
					t.Fatalf("unproved stop was reported as stopped or lost authority: %+v error=%v", failed, err)
				}
				retry := sandboxStartTestOperation(failed, now)
				if _, _, _, err := backend.BeginSandboxOperation(ctx, retry, SandboxStatePreparing); !errors.Is(err, ErrSandboxConflict) {
					t.Fatalf("start admitted without cleanup proof: %v", err)
				}
				deletion := &SandboxOperation{ID: uuid.NewString(), SandboxID: failed.ID, AccountID: failed.AccountID, IdempotencyKey: uuid.NewString(),
					Kind: SandboxOperationKindDelete, State: SandboxOperationPending, Generation: failed.Generation, FencingToken: failed.FencingToken,
					PreviousSandboxState: failed.State, CreatedAt: now, UpdatedAt: now}
				_, cleanup, created, err := backend.BeginSandboxOperation(ctx, deletion, SandboxStateDeleting)
				if err != nil || !created || cleanup.FencingToken != fence {
					t.Fatalf("cleanup lost authority: %+v error=%v", cleanup, err)
				}
			}
		})
	}
}
