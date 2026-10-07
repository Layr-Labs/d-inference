package shared

import (
	"errors"
	"math"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func ValidateFloorDrawBatch(items []store.FloorDrawBatchItem, authorize func(int) bool) error {
	if len(items) > store.FloorDrawBatchLimit {
		return errors.New("provider_floor_draw_batch_too_large")
	}
	if len(items) > 0 && authorize == nil {
		return errors.New("provider_floor_draw_batch_authorization_required")
	}
	for _, item := range items {
		if item.SessionID == "" || item.Draw.AccountID == "" || item.Draw.ProviderKey == "" || item.Draw.EpochID == "" ||
			item.Draw.EpochID != items[0].Draw.EpochID || ValidateFloorDrawAmounts(&item.Draw) != nil {
			return errors.New("invalid_provider_floor_draw_batch")
		}
	}
	return nil
}

func FloorDrawBatchRejected(index int, reason string) store.FloorDrawBatchResult {
	return store.FloorDrawBatchResult{Rejections: []store.FloorDrawBatchRejection{{Index: index, Reason: reason}}}
}

func FloorDrawBatchDuplicate(index, prior int, machine string) store.FloorDrawBatchResult {
	return store.FloorDrawBatchResult{Rejections: []store.FloorDrawBatchRejection{{Index: index, Reason: store.FloorDrawDuplicate, DuplicateOf: prior, CanonicalMachineID: machine}}}
}

// ValidateFloorDrawAmounts keeps both stores within the separate bonus pot:
// each bonus is either zero or exactly 10% of the actual base grant, rounded
// down to a whole micro-dollar. It cannot inflate a waitlisted or reduced draw.
func ValidateFloorDrawAmounts(draw *store.ProviderFloorDraw) error {
	if draw == nil || draw.AmountMicroUSD < 0 || draw.AutopilotBonusMicroUSD < 0 ||
		(draw.AutopilotBonusMicroUSD != 0 && draw.AutopilotBonusMicroUSD != draw.AmountMicroUSD/10) ||
		draw.AmountMicroUSD > math.MaxInt64-draw.AutopilotBonusMicroUSD {
		return errors.New("invalid_provider_floor_draw_amounts")
	}
	return nil
}
