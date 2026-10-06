package store

import "context"

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
