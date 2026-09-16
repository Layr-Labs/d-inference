package contracts

import (
	"context"
	"time"
)

// ReconcileMachineInventory repairs missed terminal captures from durable rows,
// including after a process restart. It never changes serving/accounting state.
type MachineInventoryReconcileStore interface {
	ReconcileMachineInventory(context.Context, time.Time, int) (int, error)
}
