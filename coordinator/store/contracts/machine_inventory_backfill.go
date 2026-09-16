package contracts

import (
	"context"
)

type MachineInventoryBackfillStore interface {
	BackfillMachineInventory(context.Context, int) (int, error)
}
