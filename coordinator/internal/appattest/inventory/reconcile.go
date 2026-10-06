// Package inventory manages bounded App Attest machine inventory work.
package inventory

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

const StaleAfter = 5 * time.Minute

// Reconciler shares admission with live inventory captures, so maintenance
// cannot consume the storage capacity needed for live identity observations.
type Reconciler struct {
	store     store.MachineInventoryReconcileStore
	slots     chan struct{}
	increment func(string, []string)
	count     func(string, int64, []string)
}

func NewReconciler(st store.MachineInventoryReconcileStore, slots chan struct{}, increment func(string, []string), count func(string, int64, []string)) *Reconciler {
	return &Reconciler{store: st, slots: slots, increment: increment, count: count}
}

func (r *Reconciler) Reconcile(ctx context.Context) {
	operation, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	if r.slots != nil {
		select {
		case r.slots <- struct{}{}:
			defer func() { <-r.slots }()
		case <-operation.Done():
			if r.increment != nil {
				r.increment("app_attest.inventory.reconcile_failed", []string{"reason:busy"})
			}
			return
		}
	}
	if operation.Err() != nil {
		return
	}
	count, err := r.store.ReconcileMachineInventory(operation, time.Now().UTC().Add(-StaleAfter), 100)
	if err != nil {
		if r.increment != nil {
			r.increment("app_attest.inventory.reconcile_failed", []string{"reason:storage_error"})
		}
	} else if count > 0 && r.count != nil {
		r.count("app_attest.inventory.reconciled", int64(count), nil)
	}
}
