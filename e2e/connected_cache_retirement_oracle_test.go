package e2e

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/stretchr/testify/require"
)

func TestConnectedRetirementObservationRejectsIdentityReplacement(t *testing.T) {
	original := protocol.PrefixCacheV2Capability{ModelID: "model", CacheEpoch: "epoch-a", Enabled: true, Ready: true}
	for _, name := range []string{"preserved", "epoch-replaced", "capability-missing", "provider-replaced", "model-replaced", "not-yet-evicted"} {
		t.Run(name, func(t *testing.T) {
			capability := original
			slot := connectedSlot{ProviderID: "provider", Model: "model", Capability: &capability,
				Capacity: &protocol.BackendCapacity{PrefixCacheMaintenance: &protocol.PrefixCacheMaintenanceTelemetry{BudgetEvictedTotal: 1}}}
			switch name {
			case "epoch-replaced":
				capability.CacheEpoch = "epoch-b"
			case "capability-missing":
				slot.Capability = nil
			case "provider-replaced":
				slot.ProviderID = "replacement"
			case "model-replaced":
				slot.Model = "other-model"
			case "not-yet-evicted":
				slot.Capacity.PrefixCacheMaintenance.BudgetEvictedTotal = 0
			}
			evicted, err := connectedRetirementObserved([]connectedSlot{slot}, "provider", "model", original)
			if name == "preserved" {
				require.NoError(t, err)
				require.True(t, evicted)
			} else if name == "not-yet-evicted" {
				require.NoError(t, err)
				require.False(t, evicted)
			} else {
				require.Error(t, err, "an eviction in a replacement identity cannot prove preservation")
				require.False(t, evicted)
			}
		})
	}
}
