// Package earningsfloor contains the durable Autopilot reward contract.
// Amounts are integer micro-USD; timestamps and settlement days are UTC.
package earningsfloor

import (
	"errors"
	"time"
)

var (
	ErrIdentity       = errors.New("autopilot reward machine identity or owner is unverified")
	ErrHistory        = errors.New("autopilot reward first-opt-in history requires verified backfill")
	ErrBaselineFrozen = errors.New("autopilot reward baseline is already frozen")
	ErrPoolCap        = errors.New("autopilot reward pool cap cannot be negative or below spending")
	ErrDayOrder       = errors.New("autopilot reward days must be settled in order")
)

// Consent is an authenticated, server-timestamped declaration. At is never
// supplied by the provider. A disconnected session does not imply opt-out.
type Consent struct {
	SessionID string
	AccountID string
	// Unsupported declarations stop eligibility but do not prove that a
	// machine had never opted in before it started reporting saved consent.
	Supported bool
	OptedIn   bool
	At        time.Time
}

type Enrollment struct {
	// HistoryConflict preserves the frozen snapshot while withholding new
	// payments when subsequently linked evidence proves its anchor uncertain.
	HistoryConflict          bool       `json:"history_conflict"`
	MachineID                string     `json:"machine_id"`
	AccountID                string     `json:"account_id"`
	FirstOptInAt             *time.Time `json:"first_opt_in_at"`
	FirstObservedAt          time.Time  `json:"first_observed_at"`
	SevenDayEarningsMicroUSD int64      `json:"seven_day_earnings_micro_usd"`
	DailyFloorMicroUSD       int64      `json:"daily_floor_micro_usd"`
	BaselineKnown            bool       `json:"baseline_known"`
	BaselineSource           string     `json:"baseline_source"`
	BaselineEvidence         string     `json:"baseline_evidence"`
	OptedIn                  bool       `json:"opted_in"`
	ObservedAt               time.Time  `json:"observed_at"`
	NextDay                  time.Time  `json:"next_day"`
}

// Baseline restores missing pre-tracking history through an authenticated admin
// operation. Evidence must identify the source for both the first-ever opt-in
// instant and the inference total in [FirstOptInAt-168h, FirstOptInAt).
type Baseline struct {
	MachineID                string    `json:"-"`
	FirstOptInAt             time.Time `json:"first_opt_in_at"`
	SevenDayEarningsMicroUSD int64     `json:"seven_day_earnings_micro_usd"`
	Evidence                 string    `json:"evidence"`
}

// Pool is a separately, manually funded cumulative allowance. Raising CapMicroUSD
// replenishes it; no calendar rollover resets spending or grants more money.
type Pool struct {
	CapMicroUSD       int64     `json:"cap_micro_usd"`
	SpentMicroUSD     int64     `json:"spent_micro_usd"`
	TrackingStartedAt time.Time `json:"tracking_started_at"`
}

const (
	TrackedBaseline  = "tracked"
	VerifiedBaseline = "verified_history"

	Paid            = "paid"
	Zero            = "zero"
	OptedOut        = "opted_out"
	PoolExhausted   = "pool_exhausted"
	HistoryRequired = "history_required"
)

// A pending pool-exhausted receipt is retried without advancing NextDay. Paid,
// zero and opted-out days are final, including across canonical identity merges.
type Settlement struct {
	MachineID         string    `json:"machine_id"`
	AccountID         string    `json:"account_id"`
	Day               time.Time `json:"day"`
	FloorMicroUSD     int64     `json:"floor_micro_usd"`
	InferenceMicroUSD int64     `json:"inference_micro_usd"`
	DueMicroUSD       int64     `json:"due_micro_usd"`
	AmountMicroUSD    int64     `json:"amount_micro_usd"`
	Status            string    `json:"status"`
	CreatedAt         time.Time `json:"created_at"`
}
