package store

import (
	"context"
	"time"
)

// MachineRewardStore associates immutable session/earning keys with verified
// inventory. It never rewrites them or certifies physical-device uniqueness.
// Callers must independently verify live authorization and authenticated account.
type MachineRewardStore interface {
	GetMachineRewardBindings(context.Context, []string) (map[string]MachineRewardBinding, error)
	SumProviderEarningsByKeysForAccount(context.Context, string, []string, time.Time, time.Time) (int64, error)
	SettleMachineFloorDraw(context.Context, string, *ProviderFloorDraw) (bool, error)
}

type MachineRewardBinding struct {
	MachineID string
	AccountID string
	// Prior machine IDs remain relevant when a floor was settled before a
	// verified alias merged identities. The canonical ID is included too.
	MachineAliases []string
}

const MachineRewardBatchLimit = 1000

// MachineFloorKey is only the key for newly issued floor credits. It never
// replaces request encryption keys, organic earning keys or older ledger rows.
func MachineFloorKey(machineID string) string { return "machine:" + machineID }
