package service_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/appattest/inventory"
)

type retryInventoryReconciler struct{ calls int }

func (s *retryInventoryReconciler) ReconcileMachineInventory(ctx context.Context, before time.Time, limit int) (int, error) {
	s.calls++
	if _, ok := ctx.Deadline(); !ok || limit != 100 || time.Since(before) < inventory.StaleAfter {
		return 0, errors.New("unbounded reconciliation")
	}
	if s.calls == 1 {
		return 0, errors.New("temporary outage")
	}
	return 1, nil
}

func TestMachineInventoryReconcileRetriesAfterContentionAndStorageFailure(t *testing.T) {
	slots := make(chan struct{}, 4)
	st := &retryInventoryReconciler{}
	reconciler := inventory.NewReconciler(st, slots, nil, nil)
	for i := 0; i < 4; i++ {
		slots <- struct{}{}
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Millisecond)
	reconciler.Reconcile(ctx)
	cancel()
	if st.calls != 0 {
		t.Fatal("reconciler bypassed inventory concurrency limit")
	}
	for i := 0; i < 4; i++ {
		<-slots
	}
	reconciler.Reconcile(context.Background()) // temporary store failure
	reconciler.Reconcile(context.Background()) // next maintenance tick
	if st.calls != 2 || len(slots) != 0 {
		t.Fatal("failed reconciliation prevented retry or leaked a permit")
	}
}
