package store

import (
	"context"
	"errors"
)

// FloorDrawBatchStore commits one remaining epoch allocation atomically. The
// caller holds WithEpochSettlementLock. authorize must be a fast, read-only
// check of the exact live connection; it must not call the store or do I/O.
// It runs at each planned credit and again before commit. A rejected identity,
// old draw, duplicate alias or lost authorization rolls back every pending row.
type FloorDrawBatchStore interface {
	SettleProviderFloorDrawBatch(context.Context, []FloorDrawBatchItem, func(int) bool) (FloorDrawBatchResult, error)
}

// The explicit bound rejects an oversized epoch without truncating it or
// committing any row. It is not a fleet-admission limit; operators must review
// transaction sizing before raising it. Caller cancellation/deadlines apply.
const FloorDrawBatchLimit = 4096

type FloorDrawBatchItem struct {
	SessionID string
	MachineID string
	Draw      ProviderFloorDraw
}

type FloorDrawBatchRejection struct {
	Index              int
	Reason             string
	DuplicateOf        int
	CanonicalMachineID string
}

type FloorDrawBatchResult struct {
	Committed  bool
	Rejections []FloorDrawBatchRejection
}

const (
	FloorDrawUnauthorized = "authorization_changed"
	FloorDrawAlreadyPaid  = "already_settled"
	FloorDrawIdentity     = "identity_changed"
	FloorDrawDuplicate    = "duplicate_machine"
)

func validateFloorDrawBatch(items []FloorDrawBatchItem, authorize func(int) bool) error {
	if len(items) > FloorDrawBatchLimit {
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

func floorDrawBatchRejected(index int, reason string) FloorDrawBatchResult {
	return FloorDrawBatchResult{Rejections: []FloorDrawBatchRejection{{Index: index, Reason: reason}}}
}

func floorDrawBatchDuplicate(index, prior int, machine string) FloorDrawBatchResult {
	return FloorDrawBatchResult{Rejections: []FloorDrawBatchRejection{{Index: index, Reason: FloorDrawDuplicate, DuplicateOf: prior, CanonicalMachineID: machine}}}
}

var (
	_ FloorDrawBatchStore = (*MemoryStore)(nil)
	_ FloorDrawBatchStore = (*PostgresStore)(nil)
)
