package memory

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"github.com/eigeninference/d-inference/coordinator/store/internal/inventorytest"
)

func readInventorySession(t *testing.T, st contracts.Store, id string) inventorytest.InventorySessionSnapshot {
	t.Helper()
	var r inventorytest.InventorySessionSnapshot
	switch s := st.(type) {
	case *Store:
		s.mu.Lock()
		defer s.mu.Unlock()
		r.Identity = s.machineInventory.sessionMachines[id]
		r.Observation = s.machineInventory.sessions[id]
		r.Account = r.Observation.AccountID
		r.Closed = r.Observation.Disconnected

	}
	return r
}

func TestMachineInventoryReconcileClosesOrphansAndPreservesLiveSessions(t *testing.T) {
	inventorytest.CheckMachineInventoryReconcile(t, New(contracts.Config{}), readInventorySession)
}
