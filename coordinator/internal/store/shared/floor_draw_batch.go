package shared

import (
	"errors"

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
			item.Draw.EpochID != items[0].Draw.EpochID || item.Draw.AmountMicroUSD < 0 {
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
