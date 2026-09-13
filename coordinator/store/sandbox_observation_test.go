package store

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestSandboxStoppedObservationPreservesPendingCommandCleanup(t *testing.T) {
	for name, raw := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			// Production's cache decorator must forward this durable capability.
			backend := NewCached(raw, CacheConfig{})
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Millisecond)
			ready := retentionSandbox(t, backend, now)
			command := retentionCommand(t, backend, ready, now.Add(-time.Minute), SandboxCommandFailed, true)
			observation := stoppedObservation(ready, now)
			for _, mutate := range []func(*SandboxStoppedObservation){
				func(o *SandboxStoppedObservation) { o.HostID = uuid.NewString() },
				func(o *SandboxStoppedObservation) { o.Generation++ },
				func(o *SandboxStoppedObservation) { o.FencingToken++ },
				func(o *SandboxStoppedObservation) { o.LeaseExpiresAt = o.LeaseExpiresAt.Add(time.Second) },
				func(o *SandboxStoppedObservation) { o.WorkspaceBytes++ },
			} {
				invalid := observation
				mutate(&invalid)
				if changed, err := backend.ObserveSandboxStopped(ctx, invalid); err != nil || changed {
					t.Fatalf("mismatched observation applied: changed=%v error=%v", changed, err)
				}
			}
			cancelled, cancel := context.WithCancel(ctx)
			cancel()
			if _, err := backend.ObserveSandboxStopped(cancelled, observation); !errors.Is(err, context.Canceled) {
				t.Fatalf("cancelled observation applied: %v", err)
			}
			if changed, err := backend.ObserveSandboxStopped(ctx, observation); err != nil || !changed {
				t.Fatalf("stopped observation: changed=%v error=%v", changed, err)
			}
			stopped, err := backend.GetSandbox(ctx, ready.AccountID, ready.ID)
			if err != nil || stopped.State != SandboxStateStopped || !stopped.ConsumesCapacity() {
				t.Fatalf("stopped allocation: %+v error=%v", stopped, err)
			}
			pending, err := backend.GetSandboxCommand(ctx, ready.AccountID, ready.ID, command.ID)
			if err != nil || !pending.CancellationPending || pending.State != SandboxCommandFailed {
				t.Fatalf("observation erased command cleanup: %+v error=%v", pending, err)
			}
			start := sandboxStartTestOperation(stopped, now)
			if _, _, _, err := backend.BeginSandboxOperation(ctx, start, SandboxStatePreparing); !errors.Is(err, ErrSandboxConflict) {
				t.Fatalf("resume admitted before command cleanup: %v", err)
			}
			if _, err := backend.ApplySandboxCommandUpdate(ctx, SandboxCommandUpdate{CommandID: command.ID, SandboxID: ready.ID, Generation: ready.Generation,
				FencingToken: ready.FencingToken, State: SandboxCommandCancelled, UpdatedAt: now}); err != nil {
				t.Fatal(err)
			}
			if _, _, created, err := backend.BeginSandboxOperation(ctx, start, SandboxStatePreparing); err != nil || !created {
				t.Fatalf("resume after cleanup: created=%v error=%v", created, err)
			}
			if changed, err := backend.ObserveSandboxStopped(ctx, observation); err != nil || changed {
				t.Fatalf("old stopped observation interrupted pending start: %v %v", changed, err)
			}
		})
	}
}

func TestSandboxStoppedObservationCannotInterruptLifecycle(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Millisecond)
			ready := retentionSandbox(t, backend, now)
			renew := &SandboxOperation{ID: uuid.NewString(), SandboxID: ready.ID, AccountID: ready.AccountID, IdempotencyKey: uuid.NewString(),
				Kind: SandboxOperationKindRenew, State: SandboxOperationPending, Generation: ready.Generation, FencingToken: ready.FencingToken,
				RequestedFencingToken: ready.FencingToken + 1, RequestedLeaseExpiresAt: ready.LeaseExpiresAt.Add(time.Minute), PreviousSandboxState: ready.State, CreatedAt: now, UpdatedAt: now}
			_, pending, _, err := backend.BeginSandboxOperation(ctx, renew, SandboxStateReady)
			if err != nil {
				t.Fatal(err)
			}
			if changed, err := backend.ObserveSandboxStopped(ctx, stoppedObservation(ready, now)); err != nil || changed {
				t.Fatalf("observation raced pending renewal: %v %v", changed, err)
			}
			resumed, _, err := backend.ApplySandboxOperationUpdate(ctx, SandboxOperationUpdate{OperationID: pending.ID, SandboxID: ready.ID,
				Generation: ready.Generation, FencingToken: pending.RequestedFencingToken, State: SandboxOperationReady, LeaseExpiresAt: &pending.RequestedLeaseExpiresAt, UpdatedAt: now})
			if err != nil {
				t.Fatal(err)
			}
			if changed, err := backend.ObserveSandboxStopped(ctx, stoppedObservation(ready, now)); err != nil || changed {
				t.Fatalf("old fence stopped renewed lease: %v %v", changed, err)
			}
			if changed, err := backend.ObserveSandboxStopped(ctx, stoppedObservation(resumed, now)); err != nil || !changed {
				t.Fatalf("current fence not accepted: %v %v", changed, err)
			}
		})
	}
}

func stoppedObservation(sandbox *SandboxRecord, now time.Time) SandboxStoppedObservation {
	return SandboxStoppedObservation{SandboxID: sandbox.ID, HostID: sandbox.HostID, Generation: sandbox.Generation, FencingToken: sandbox.FencingToken,
		CPUCount: sandbox.CPUCount, MemoryBytes: sandbox.MemoryBytes, WorkspaceBytes: sandbox.WorkspaceBytes, CommandTimeoutSeconds: sandbox.CommandTimeoutSeconds,
		GPU: sandbox.GPU, LeaseExpiresAt: sandbox.LeaseExpiresAt, ObservedAt: now}
}
