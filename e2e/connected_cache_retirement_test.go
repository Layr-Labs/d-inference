package e2e

import (
	"encoding/json"
	"fmt"
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
	var originalCapability *protocol.PrefixCacheV2Capability
	providerID := report.Cases[0].HTTP.ProviderID
	for _, slot := range report.Cases[0].SlotsBefore {
		if slot.ProviderID == providerID && slot.Model == model && slot.Capability != nil {
			copy := *slot.Capability
			originalCapability = &copy
		}
	}
	require.NotNil(t, originalCapability, "original provider/model cache capability is required")
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
	var observationError error
	require.Eventually(t, func() bool {
		snapshot := connectedSlots(suite, model)
		evicted, err := connectedRetirementObserved(snapshot, providerID, model, *originalCapability)
		observationError = err
		// A changed identity ends the wait so the original failure is reported,
		// rather than silently waiting for another epoch to report an eviction.
		return err != nil || evicted
	}, 150*time.Second, 250*time.Millisecond, "no observed active-store eviction; pressure gate not exercised")
	require.NoError(t, observationError)
	refreshed := connectedSlots(suite, model)
	evicted, err := connectedRetirementObserved(refreshed, providerID, model, *originalCapability)
	require.NoError(t, err, "refreshed post-eviction identity must still match the original")
	require.True(t, evicted, "refreshed snapshot must retain the observed eviction")
	report.Cases[2].SlotsAfter = refreshed
	t.Logf("CACHE_RETIREMENT connected=true native_cached=%v ready_accepted=true epoch=preserved eviction_observed=true natural_routing=true", restored)
}

func connectedRetirementObserved(slots []connectedSlot, providerID, model string, original protocol.PrefixCacheV2Capability) (bool, error) {
	for _, slot := range slots {
		if slot.ProviderID != providerID || slot.Model != model {
			continue
		}
		if slot.Capability == nil || *slot.Capability != original {
			return false, fmt.Errorf("routine retirement changed the original provider/model cache capability")
		}
		if slot.Capacity == nil {
			return false, nil
		}
		if maintenance := slot.Capacity.PrefixCacheMaintenance; maintenance != nil && maintenance.BudgetEvictedTotal > 0 {
			return true, nil
		}
		for _, modelSlot := range slot.Capacity.Slots {
			if modelSlot.Model == model && modelSlot.PrefixCache != nil && modelSlot.PrefixCache.EvictionsTotal > 0 {
				return true, nil
			}
		}
		return false, nil
	}
	return false, fmt.Errorf("original provider/model cache capability is missing after retirement")
}
