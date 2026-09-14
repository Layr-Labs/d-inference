package store

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestSandboxStartPreservesAllocationAndCommandHistory(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Millisecond)
			ready := retentionSandbox(t, backend, now)
			command := retentionCommand(t, backend, ready, now.Add(-time.Minute), SandboxCommandSucceeded, false)
			stopped, stop := stopSandboxForStart(t, backend, ready, now)
			start := sandboxStartTestOperation(stopped, now.Add(time.Second))
			preparing, stored, created, err := backend.BeginSandboxOperation(ctx, start, SandboxStatePreparing)
			if err != nil || !created || preparing.State != SandboxStatePreparing || stored.RequestedFencingToken <= stopped.FencingToken {
				t.Fatalf("begin start: sandbox=%+v operation=%+v created=%v error=%v", preparing, stored, created, err)
			}
			if preparing.FencingToken != stopped.FencingToken {
				t.Fatal("start advanced coordinator authority before host proof")
			}
			update := SandboxOperationUpdate{OperationID: stored.ID, SandboxID: stopped.ID, Generation: stopped.Generation,
				FencingToken: stopped.FencingToken, State: SandboxOperationReady, LeaseExpiresAt: &stopped.LeaseExpiresAt, UpdatedAt: now.Add(2 * time.Second)}
			if _, _, err := backend.ApplySandboxOperationUpdate(ctx, update); !errors.Is(err, ErrSandboxConflict) {
				t.Fatalf("ready without fence rotation: %v", err)
			}
			update.FencingToken, update.State = stored.RequestedFencingToken, SandboxOperationBooting
			booting, _, err := backend.ApplySandboxOperationUpdate(ctx, update)
			if err != nil || booting.FencingToken != stored.RequestedFencingToken || booting.State != SandboxStatePreparing {
				t.Fatalf("booting authority: %+v %v", booting, err)
			}
			if _, _, err := backend.ApplySandboxOperationUpdate(ctx, SandboxOperationUpdate{OperationID: stop.ID, SandboxID: stopped.ID,
				Generation: stopped.Generation, FencingToken: stopped.FencingToken, State: SandboxOperationStopped, UpdatedAt: now.Add(3 * time.Second)}); !errors.Is(err, ErrSandboxConflict) {
				t.Fatalf("delayed stop altered resumed allocation: %v", err)
			}
			update.State, update.UpdatedAt = SandboxOperationReady, now.Add(3*time.Second)
			resumed, _, err := backend.ApplySandboxOperationUpdate(ctx, update)
			if err != nil || resumed.State != SandboxStateReady || resumed.HostID != ready.HostID || resumed.Generation != ready.Generation ||
				!resumed.LeaseExpiresAt.Equal(ready.LeaseExpiresAt) || resumed.WorkspaceBytes != ready.WorkspaceBytes || resumed.MemoryBytes != ready.MemoryBytes || resumed.CPUCount != ready.CPUCount {
				t.Fatalf("resume changed allocation: %+v error=%v", resumed, err)
			}
			if _, _, err := backend.ApplySandboxOperationUpdate(ctx, update); err != nil {
				t.Fatalf("replayed ready: %v", err)
			}
			if _, replay, created, err := backend.BeginSandboxOperation(ctx, start, SandboxStatePreparing); err != nil || created || replay.ID != stored.ID || replay.RequestedFencingToken != stored.RequestedFencingToken {
				t.Fatalf("replayed start allocated another fence: %+v created=%v error=%v", replay, created, err)
			}
			retry := cloneSandboxCommand(command)
			retry.ID, retry.Generation, retry.FencingToken = uuid.NewString(), resumed.Generation, resumed.FencingToken
			old, created, err := backend.CreateSandboxCommand(ctx, retry)
			if err != nil || created || old.ID != command.ID || old.State != SandboxCommandSucceeded {
				t.Fatalf("old command executed again after resume: %+v created=%v error=%v", old, created, err)
			}
			active, err := backend.ListActiveSandboxesByHost(ctx, ready.HostID)
			if err != nil || len(active) != 1 || active[0].ID != ready.ID {
				t.Fatalf("resume duplicated capacity: %+v error=%v", active, err)
			}
			if _, err := backend.GetSandboxOperation(ctx, "different-account", stored.ID); !errors.Is(err, ErrNotFound) {
				t.Fatalf("start crossed account boundary: %v", err)
			}
		})
	}
}

func TestSandboxStartRejectsExpiryAndRetainsFailedRotation(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Millisecond)
			for _, rotated := range []bool{false, true} {
				stopped, _ := stopSandboxForStart(t, backend, retentionSandbox(t, backend, now), now)
				start := sandboxStartTestOperation(stopped, now.Add(time.Second))
				invalid := *start
				invalid.RequestedLeaseExpiresAt = stopped.LeaseExpiresAt.Add(time.Second)
				if _, _, _, err := backend.BeginSandboxOperation(ctx, &invalid, SandboxStatePreparing); !errors.Is(err, ErrSandboxConflict) {
					t.Fatalf("start extended expiry: %v", err)
				}
				invalid = *start
				invalid.CreatedAt = stopped.LeaseExpiresAt
				if _, _, _, err := backend.BeginSandboxOperation(ctx, &invalid, SandboxStatePreparing); !errors.Is(err, ErrSandboxConflict) {
					t.Fatalf("expired start admitted: %v", err)
				}
				_, op, _, err := backend.BeginSandboxOperation(ctx, start, SandboxStatePreparing)
				if err != nil {
					t.Fatal(err)
				}
				fence := stopped.FencingToken
				if rotated {
					fence = op.RequestedFencingToken
				}
				update := SandboxOperationUpdate{OperationID: op.ID, SandboxID: stopped.ID, Generation: stopped.Generation,
					FencingToken: fence, State: SandboxOperationFailed, ErrorCode: "guest_unavailable", UpdatedAt: now.Add(2 * time.Second)}
				failed, _, err := backend.ApplySandboxOperationUpdate(ctx, update)
				if err != nil || failed.State != SandboxStateStopped || failed.FencingToken != fence || !failed.LeaseExpiresAt.Equal(stopped.LeaseExpiresAt) {
					t.Fatalf("start failure lost cleanup authority: %+v error=%v", failed, err)
				}
				if rotated {
					update.FencingToken = stopped.FencingToken
					if _, _, err := backend.ApplySandboxOperationUpdate(ctx, update); !errors.Is(err, ErrSandboxConflict) {
						t.Fatalf("failure replay rolled authority back: %v", err)
					}
				}
			}
		})
	}
}

func TestSandboxStartSerializesConcurrentRetriesAndRejectsPendingWork(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Millisecond)
			stopped, _ := stopSandboxForStart(t, backend, retentionSandbox(t, backend, now), now)
			start := sandboxStartTestOperation(stopped, now.Add(time.Second))
			renew := *start
			renew.ID, renew.IdempotencyKey, renew.Kind = uuid.NewString(), uuid.NewString(), SandboxOperationKindRenew
			renew.RequestedLeaseExpiresAt = stopped.LeaseExpiresAt.Add(time.Minute)
			_, pending, _, err := backend.BeginSandboxOperation(ctx, &renew, SandboxStateStopped)
			if err != nil {
				t.Fatal(err)
			}
			if _, _, _, err := backend.BeginSandboxOperation(ctx, start, SandboxStatePreparing); !errors.Is(err, ErrSandboxConflict) {
				t.Fatalf("start admitted while renewal pending: %v", err)
			}
			if _, _, err := backend.ApplySandboxOperationUpdate(ctx, SandboxOperationUpdate{OperationID: pending.ID, SandboxID: stopped.ID,
				Generation: stopped.Generation, FencingToken: stopped.FencingToken, State: SandboxOperationFailed, UpdatedAt: now}); err != nil {
				t.Fatal(err)
			}
			gate := make(chan struct{})
			type result struct {
				operation *SandboxOperation
				created   bool
				err       error
			}
			results := make(chan result, 2)
			for range 2 {
				retry := *start
				retry.ID = uuid.NewString()
				go func() {
					<-gate
					_, operation, created, err := backend.BeginSandboxOperation(ctx, &retry, SandboxStatePreparing)
					results <- result{operation, created, err}
				}()
			}
			close(gate)
			first, second := <-results, <-results
			if first.err != nil || second.err != nil || first.created == second.created || first.operation.ID != second.operation.ID || first.operation.RequestedFencingToken != second.operation.RequestedFencingToken {
				t.Fatalf("concurrent starts did not serialize: %+v %+v", first, second)
			}
			other, _ := stopSandboxForStart(t, backend, retentionSandbox(t, backend, now), now)
			if _, err := backend.MarkSandboxTerminationRequested(ctx, other.AccountID, other.ID, uuid.NewString(), now); err != nil {
				t.Fatal(err)
			}
			if _, _, _, err := backend.BeginSandboxOperation(ctx, sandboxStartTestOperation(other, now), SandboxStatePreparing); !errors.Is(err, ErrSandboxConflict) {
				t.Fatalf("start admitted during termination: %v", err)
			}
		})
	}
}

func stopSandboxForStart(t *testing.T, backend SandboxStore, ready *SandboxRecord, now time.Time) (*SandboxRecord, *SandboxOperation) {
	t.Helper()
	operation := &SandboxOperation{ID: uuid.NewString(), SandboxID: ready.ID, AccountID: ready.AccountID, IdempotencyKey: uuid.NewString(),
		Kind: SandboxOperationKindStop, State: SandboxOperationPending, Generation: ready.Generation, FencingToken: ready.FencingToken,
		PreviousSandboxState: ready.State, CreatedAt: now, UpdatedAt: now}
	_, stop, _, err := backend.BeginSandboxOperation(context.Background(), operation, SandboxStateStopping)
	if err != nil {
		t.Fatal(err)
	}
	stopped, _, err := backend.ApplySandboxOperationUpdate(context.Background(), SandboxOperationUpdate{OperationID: stop.ID,
		SandboxID: ready.ID, Generation: ready.Generation, FencingToken: ready.FencingToken, State: SandboxOperationStopped, UpdatedAt: now})
	if err != nil {
		t.Fatal(err)
	}
	return stopped, stop
}

func sandboxStartTestOperation(stopped *SandboxRecord, now time.Time) *SandboxOperation {
	return &SandboxOperation{ID: uuid.NewString(), SandboxID: stopped.ID, AccountID: stopped.AccountID, IdempotencyKey: uuid.NewString(),
		Kind: SandboxOperationKindStart, State: SandboxOperationPending, Generation: stopped.Generation, FencingToken: stopped.FencingToken,
		PreviousSandboxState: SandboxStateStopped, RequestedFencingToken: stopped.FencingToken + 1,
		RequestedLeaseExpiresAt: stopped.LeaseExpiresAt, CreatedAt: now, UpdatedAt: now}
}
