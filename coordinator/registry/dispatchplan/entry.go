package dispatchplan

import (
	"time"
)

// Entry is the exported view of one retained alternate: the ranking and
// revalidation terms dispatch code needs for hedge timing and telemetry,
// captured at scan time. Estimates are scan-time values — ReserveNextFromPlan
// recomputes everything against live state before reserving.
type Entry struct {
	ProviderID string
	// CostMs is the candidate's full routing cost at scan time (same quantity
	// selectRoutingCandidate ranked by).
	CostMs float64
	// TTFTMs is the calibrated scan-time TTFT estimate (0 when the provider
	// reports no BackendCapacity — unreliable, matching the scan's ceiling
	// exemption). RawTTFTMs is the uncalibrated formula value alongside.
	TTFTMs    float64
	RawTTFTMs float64
	// StateMs is the slot-state penalty (0 = warm/running; large = cold load
	// ahead). ModelLoaded/SlotState carry the warm/idle detail.
	StateMs     float64
	ModelLoaded bool
	SlotState   string
	ChipFamily  string

	// Capacity-probe enrichment (probe.go). Confirmed is set by an
	// affirmative capacity_quote, Demoted by a negative quote, probe timeout,
	// or transport failure; both false = unprobed/legacy (ledger-scored,
	// mid-tier). The Quote* fields carry the provider's own live estimate and
	// are meaningful only while Confirmed.
	Confirmed bool
	Demoted   bool
	// QuoteTTFTP50/P90 are the quoted end-to-end TTFT distribution quantiles
	// (durations — the wire carries ms floats). P50 is telemetry view only;
	// production hedge timing reads P90 via BestConfirmedBackup.
	QuoteTTFTP50 time.Duration
	QuoteTTFTP90 time.Duration
	// QuoteAvailableTokens is the quoted live token headroom of the admitting
	// gate; QuoteConfidence is protocol.CapacityConfidenceHigh/Low. Telemetry
	// view; no production consumer reads these off the plan today.
	QuoteAvailableTokens int64
	QuoteConfidence      string
}

// Retained pairs a scan-time view with the exact opaque connection.
// Only the registry reservation adapter may turn it into a live reservation.
type Retained[C comparable] struct {
	Connection C
	View       Entry
}
