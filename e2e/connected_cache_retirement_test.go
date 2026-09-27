package e2e

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/e2e/testbed"
	"github.com/stretchr/testify/require"
)

type connectedCacheRunOptions struct{ retirementOnly bool }

// Requires the same explicit immutable input as the ordinary connected suite.
// Only freshly owned provider roots receive this test's disk-budget override.
func TestIntegrationConnectedCacheRetirement(t *testing.T) {
	runConnectedCacheHTTP(t, "DARKBLOOM_CONNECTED_CACHE_INPUT", "DARKBLOOM_CONNECTED_CACHE_OUTPUT", false,
		connectedCacheRunOptions{retirementOnly: true})
}

func verifyConnectedRetirement(t *testing.T, suite *testbed.Suite, model string, report *connectedReport) {
	t.Helper()
	var restored []int
	for i, row := range report.Cases {
		var before, after string
		for _, slot := range row.SlotsBefore {
			if slot.ProviderID == row.HTTP.ProviderID && slot.Capability != nil {
				before = slot.Capability.CacheEpoch
			}
		}
		for _, slot := range row.SlotsAfter {
			if slot.ProviderID == row.HTTP.ProviderID && slot.Capability != nil {
				after = slot.Capability.CacheEpoch
			}
		}
		require.NotEmpty(t, before)
		require.Equal(t, before, after, "routine retirement changed the active model generation")
		require.Positive(t, row.After.Holders, "surviving checkpoint must be discoverable")
		require.Equal(t, row.Before.Lifecycle.DonationOutcomes["cache_epoch_changed"], row.After.Lifecycle.DonationOutcomes["cache_epoch_changed"])
		if i > 0 {
			require.Equal(t, report.Cases[0].HTTP.Content, row.HTTP.Content)
			require.Equal(t, report.Cases[0].HTTP.Reasoning, row.HTTP.Reasoning)
			var usage protocol.UsageInfo
			for _, event := range row.Wire {
				if event.Type == protocol.TypeInferenceComplete {
					require.NoError(t, json.Unmarshal(event.Fields["usage"], &usage))
				}
			}
			// LRU timestamps have second resolution: either native endpoint can
			// survive a tie. Require a real, previously advertised survivor,
			// not an invented guarantee that the larger checkpoint always wins.
			require.Contains(t, []int{2048, 4096}, usage.CachedTokens)
			if i == 2 {
				require.Equal(t, 4096, usage.CachedTokens, "the stable repeat must use the refilled deepest endpoint")
			}
			require.NoError(t, validateConnectedBranch(row, report.Cases[:i]))
			restored = append(restored, usage.CachedTokens)
		}
	}
	// Prove that disk pressure actually retired data; a passing repeat without
	// any eviction would not exercise this regression. Do not lower refresh
	// intervals or conflate these delayed counters with per-request timings.
	require.Eventually(t, func() bool {
		for _, slot := range connectedSlots(suite, model) {
			if slot.ProviderID != report.Cases[0].HTTP.ProviderID || slot.Capacity == nil {
				continue
			}
			if maintenance := slot.Capacity.PrefixCacheMaintenance; maintenance != nil && maintenance.BudgetEvictedTotal > 0 {
				return true
			}
			for _, modelSlot := range slot.Capacity.Slots {
				if modelSlot.Model == model && modelSlot.PrefixCache != nil && modelSlot.PrefixCache.EvictionsTotal > 0 {
					return true
				}
			}
		}
		return false
	}, 150*time.Second, 250*time.Millisecond, "no observed active-store eviction; pressure gate not exercised")
	report.Cases[2].SlotsAfter = connectedSlots(suite, model)
	t.Logf("CACHE_RETIREMENT connected=true native_cached=%v ready_accepted=true epoch=preserved eviction_observed=true natural_routing=true", restored)
}
