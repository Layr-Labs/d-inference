package routingcost

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry/admission"
)

// Snapshot is caller-owned value storage populated under the caller's live
// state locks. Calculations only read it; Provider is an opaque connection
// identity. Registry writes this same layout directly into its candidate arena.
type Snapshot[Connection comparable] struct {
	Provider   Connection
	Model      string
	ChipFamily string // hardware chip family (e.g. "M3"); keys the TTFT calibrator
	// BinaryVersion is the Provider's reported binary version (p.Version, read
	// under p.mu at snapshot time; empty = unreported/legacy). Feeds the
	// version-gated activation-reserve selection in the cold servability
	// estimate (admission.Policy.ActivationFloor) so a mixed-version fleet
	// is charged the reserve each binary actually holds.
	BinaryVersion    string
	SlotState        string
	HasHeadroom      bool
	TotalPending     int
	PendingForModel  int
	PendingMaxTokens int
	// Pending prompt work before first content, for the matching Model. These
	// aggregates price reservations not yet reflected by an idle heartbeat.
	// Unknown sizes and cache participants retain the incoming-prompt proxy.
	// Token-budget reservations (including output) remain memory accounting.
	PendingPrefillTokens  float64
	PendingPrefillUnknown int
	PendingPrefillKnown   bool
	// PendingMaxTokensAllModels is PendingMaxTokens WITHOUT the Model filter:
	// the token budgets of every coordinator-pending request on this Provider,
	// any Model. Feeds the pooled-budget admission check (pooledBudgetAdmits)
	// so co-resident models cannot double-spend shared legacy headroom and do
	// not lose additive private-grant capacity on v0.7.5+ providers.
	PendingMaxTokensAllModels int
	// PendingMaxBytesAllModels is the byte-normalized analog: each pending
	// request's token budget × its Model's reported KVBytesPerToken. Valid
	// only when PendingBytesKnown. A cold request without a reported Model rate
	// is charged at the bounded conservative default (see
	// fillSnapshotPendingAndPool), so it cannot disable byte accounting for a
	// reconstructable pool. Co-resident models have different per-token byte
	// rates, so tokens are not a common unit across models (admission/pool.go).
	PendingMaxBytesAllModels int64
	PendingBytesKnown        bool
	BackendRunning           int
	BackendWaiting           int
	MaxTokensPotential       int64
	DecodeTPS                float64
	PrefillTPS               float64
	SystemMetrics            protocol.SystemMetrics
	GPUMemoryActiveGB        float64
	TotalMemoryGB            float64
	// FreeForLoadGB is the Provider-reported max additional Model-weight (GB) it
	// can load right now (net of cap/reserve/headroom, idle models reclaimed).
	// When non-nil it is the authoritative cold-load gate; nil = legacy Provider
	// (fall back to the total-memory heuristic). See protocol.BackendCapacity.
	FreeForLoadGB   *float64
	ModelSizeGB     float64 // catalog-reported weight footprint (0 = unknown, gate disabled)
	MinRAMGB        int     // catalog authoritative min RAM (GB) to run the Model (0 = unknown)
	ModelLoaded     bool    // true when the requested Model is resident (running or idle)
	AvailableOnDisk bool    // Model is in Provider's Models list but not currently loaded

	ObservedDecodeTPS     float64
	ObservedPrefillTPS    float64 // measured per-slot prefill EWMA; 0 = unreported (fall back to PrefillTPS chain)
	ActiveTokenBudgetUsed int64
	ActiveTokenBudgetMax  int64
	QueuedTokenBudget     int64
	// PooledTokenBudget is the Provider's reconstructed whole-box token budget
	// (all budget slots; layout selected from the Provider release version).
	// Zero value when the Provider reports no backend capacity / no budget
	// slots, which disables the pooled admission check.
	PooledTokenBudget admission.Pool
	// BudgetClamped means the gray-box budget clamp (faultstate/budget_clamp.go) is
	// active for this (Provider, Model) pair: a capacity-shaped 503 proved the
	// Provider's LIVE admission gate is rejecting, so the heartbeat budget
	// above is stale-optimistic and admission must treat the slot as FULL
	// (freeMemoryAdmits rejects; providerBudgetFits reports zero live
	// headroom). The budget fields themselves stay RAW — cost/backlog math,
	// the structural servability ceiling (snapshotStructuralBudget), and
	// telemetry keep reading the Provider-reported truth. Only set when the
	// slot reports a token budget (ActiveTokenBudgetMax > 0).
	BudgetClamped bool
	// KVBytesPerToken is the Provider-reported per-token KV-cache cost (bytes)
	// for THIS Model's slot (BackendSlotCapacity.KVBytesPerToken). 0 = unreported
	// (callers fall back to the kvCacheBytesPerToken default). Used by the
	// servability predictor to estimate a cold Provider's post-load token budget
	// the same way the Provider does, instead of the fixed default.
	KVBytesPerToken    int64
	FleetMedianTPS     float64
	HasBackendCapacity bool // Provider reports BackendCapacity; TTFT estimates are reliable

	// Engine-health (first-token wedge) signals, decoded from the slot's
	// BackendSlotCapacity (see docs/reports/2026-06-22-cancel-root-cause-and-fix.md
	// §C). MEASUREMENT ONLY: surfaced here so routing/observability code can read
	// a wedge ("Admits climbing, first-tokens flat, steps frozen") — this PR does
	// NOT gate any routing decision on them. 0/false for legacy providers.
	StepsExecuted              int64
	Admits                     int64
	FirstTokensEmitted         int64
	SecondsSinceLastStep       float64
	SecondsSinceLastFirstToken float64
	WedgeSuspected             bool
	EvalInFlightMs             int64
	IdleClearInFlightMs        int64

	// HBAgeMs is the age of p.LastHeartbeat at snapshot time (now − LastHeartbeat,
	// clamped to int32), computed from the `now` the snapshot already reads — no
	// extra clock read. It is the "how stale were the routing inputs" signal of
	// the system-profiler routing record (RoutingDecision.SnapshotAgeMs for the
	// winner, CandidateSummary.HBAgeMs for the top candidates). Observability
	// only; routing is NOT gated on it.
	HBAgeMs int32
	// QueuedPrefillTokens is the slot's Provider-reported Σ prompt tokens of
	// requests whose engine submit has not returned (slice-2 SlotTelemetry
	// producer). 0 until the wire field exists: BackendSlotCapacity has no
	// telemetry sub-object at this compile point, so nothing populates it yet.
	QueuedPrefillTokens int64
}
