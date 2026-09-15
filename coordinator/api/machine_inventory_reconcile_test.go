package api

import (
	"context"
	"errors"
	"testing"
	"time"
)

type retryInventoryReconciler struct{ calls int }

func (s *retryInventoryReconciler) ReconcileMachineInventory(ctx context.Context, before time.Time, limit int) (int, error) {
	s.calls++
	if _, ok := ctx.Deadline(); !ok || limit != 100 || time.Since(before) < machineInventoryStaleAfter {
		return 0, errors.New("unbounded reconciliation")
	}
	if s.calls == 1 {
		return 0, errors.New("temporary outage")
	}
	return 1, nil
}

func TestMachineInventoryReconcileRetriesAfterContentionAndStorageFailure(t *testing.T) {
	s := &Server{machineInventorySlots: make(chan struct{}, 4)}
	st := &retryInventoryReconciler{}
	for i := 0; i < 4; i++ {
		s.machineInventorySlots <- struct{}{}
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Millisecond)
	s.reconcileMachineInventory(ctx, st)
	cancel()
	if st.calls != 0 {
		t.Fatal("reconciler bypassed inventory concurrency limit")
	}
	for i := 0; i < 4; i++ {
		<-s.machineInventorySlots
	}
	s.reconcileMachineInventory(context.Background(), st) // temporary store failure
	s.reconcileMachineInventory(context.Background(), st) // next maintenance tick
	if st.calls != 2 || len(s.machineInventorySlots) != 0 {
		t.Fatal("failed reconciliation prevented retry or leaked a permit")
	}
}
