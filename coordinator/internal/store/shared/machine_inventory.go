package shared

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

const InventoryStaleDisconnectReason = "inventory_stale"

// A delayed capture cannot overwrite newer liveness or reopen a confirmed
// disconnect. A fresh capture may revive a closure inferred from stale data.
func InventoryObservationSuperseded(lastSeen time.Time, disconnected bool, reason string, next store.MachineObservation) bool {
	return next.At.Before(lastSeen) || disconnected && (reason != InventoryStaleDisconnectReason || !next.At.After(lastSeen))
}

func StrongerAssurance(a, b string) string {
	if a == "" {
		return b
	}
	rank := map[string]int{"provisional": 0, "key_bound": 1, "hardware_verified": 2}
	if rank[b] > rank[a] {
		return b
	}
	return a
}
