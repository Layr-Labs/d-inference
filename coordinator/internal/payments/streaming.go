package payments

import (
	"log/slog"
	"sync"
	"time"

	"github.com/eigeninference/coordinator/internal/protocol"
	"github.com/eigeninference/coordinator/internal/store"
)

// StreamEngine pays providers a fixed monthly rate streamed per-heartbeat.
//
// Each heartbeat from an eligible provider earns a micro-payment proportional
// to the time elapsed since the last eligible heartbeat. The monthly rate is
// derived from the provider's hardware (chip + memory). This incentivizes
// providers to stay online with memory available, even when there is no
// consumer demand.
//
// Eligibility per heartbeat:
//   - Provider status is "idle" or "serving" (not offline/unknown)
//   - Memory pressure < MaxMemoryPressure (default 0.85)
//   - Thermal state is not "critical"
//   - Time since last payment > MinPaymentInterval (prevents double-pay on reconnect)
//
// Payments are credited to the provider's linked account (if device-auth'd)
// via the store's ledger. Unlinked providers accrue but are not paid until
// they link an account.

const (
	// DefaultMaxMemoryPressure is the ceiling above which streaming payments
	// pause. At 85%+ memory pressure, the machine is too constrained to serve.
	DefaultMaxMemoryPressure = 0.85

	// MinPaymentInterval prevents double-crediting on fast reconnects.
	// Must be at least 3 seconds (heartbeat is 5s default).
	MinPaymentInterval = 3 * time.Second

	// MaxPaymentGap caps the elapsed time credited per single heartbeat.
	// If a provider hasn't sent a heartbeat in > 60s, we only credit 60s
	// to prevent retroactive lump payments after long disconnects.
	MaxPaymentGap = 60 * time.Second
)

// StreamRate defines a monthly USD rate for a hardware class.
type StreamRate struct {
	MonthlyMicroUSD int64  // micro-USD per month (e.g. 15_000_000 = $15/mo)
	Description     string // human-readable label
}

// streamRateTable maps (chip_family, memory_gb) to a monthly rate.
// The lookup tries exact (family, mem) first, then falls back to family-only,
// then to a base rate. Rates are set to give $10-$20/mo range based on hardware.
//
// Pricing rationale:
//   - Base rate: $10/mo — minimum for any Apple Silicon Mac
//   - Better chips and more memory command higher rates
//   - M4 Max/Ultra with 128GB+ gets $20/mo (top tier)
//   - Memory thresholds: 16GB base, 32GB mid, 64GB+ high, 128GB+ max
var streamRateTable = map[string]StreamRate{
	// Base fallback for any Apple Silicon
	"base": {MonthlyMicroUSD: 10_000_000, Description: "Base Apple Silicon"},

	// --- M1 family ---
	"m1:16":  {MonthlyMicroUSD: 10_000_000, Description: "M1 16GB"},
	"m1:24":  {MonthlyMicroUSD: 11_000_000, Description: "M1 24GB"},
	"m1:32":  {MonthlyMicroUSD: 12_000_000, Description: "M1 32GB"},
	"m1:64":  {MonthlyMicroUSD: 13_000_000, Description: "M1 64GB"},
	"m1:96":  {MonthlyMicroUSD: 14_000_000, Description: "M1 96GB"},
	"m1:128": {MonthlyMicroUSD: 15_000_000, Description: "M1 128GB"},

	// --- M2 family ---
	"m2:16":  {MonthlyMicroUSD: 10_500_000, Description: "M2 16GB"},
	"m2:24":  {MonthlyMicroUSD: 11_500_000, Description: "M2 24GB"},
	"m2:32":  {MonthlyMicroUSD: 13_000_000, Description: "M2 32GB"},
	"m2:64":  {MonthlyMicroUSD: 14_000_000, Description: "M2 64GB"},
	"m2:96":  {MonthlyMicroUSD: 15_000_000, Description: "M2 96GB"},
	"m2:128": {MonthlyMicroUSD: 16_000_000, Description: "M2 128GB"},
	"m2:192": {MonthlyMicroUSD: 17_000_000, Description: "M2 192GB"},

	// --- M3 family ---
	"m3:16":  {MonthlyMicroUSD: 11_000_000, Description: "M3 16GB"},
	"m3:24":  {MonthlyMicroUSD: 12_000_000, Description: "M3 24GB"},
	"m3:36":  {MonthlyMicroUSD: 13_000_000, Description: "M3 36GB"},
	"m3:48":  {MonthlyMicroUSD: 14_000_000, Description: "M3 48GB"},
	"m3:64":  {MonthlyMicroUSD: 15_000_000, Description: "M3 64GB"},
	"m3:96":  {MonthlyMicroUSD: 16_000_000, Description: "M3 96GB"},
	"m3:128": {MonthlyMicroUSD: 17_000_000, Description: "M3 128GB"},

	// --- M4 family ---
	"m4:16":  {MonthlyMicroUSD: 12_000_000, Description: "M4 16GB"},
	"m4:24":  {MonthlyMicroUSD: 13_000_000, Description: "M4 24GB"},
	"m4:32":  {MonthlyMicroUSD: 14_000_000, Description: "M4 32GB"},
	"m4:36":  {MonthlyMicroUSD: 14_500_000, Description: "M4 36GB"},
	"m4:48":  {MonthlyMicroUSD: 15_500_000, Description: "M4 48GB"},
	"m4:64":  {MonthlyMicroUSD: 17_000_000, Description: "M4 64GB"},
	"m4:128": {MonthlyMicroUSD: 19_000_000, Description: "M4 128GB"},
	"m4:192": {MonthlyMicroUSD: 20_000_000, Description: "M4 192GB"},
	"m4:256": {MonthlyMicroUSD: 20_000_000, Description: "M4 256GB"},
}

// LookupStreamRate returns the monthly micro-USD rate for the given hardware.
// Falls back through: exact (family:mem) → nearest lower memory for family → base.
func LookupStreamRate(hw protocol.Hardware) StreamRate {
	family := hw.ChipFamily
	mem := hw.MemoryGB

	// Try exact match first.
	key := family + ":" + memBucket(mem)
	if rate, ok := streamRateTable[key]; ok {
		return rate
	}

	// Fall back to nearest lower memory bucket for this family.
	for _, bucket := range []int{128, 96, 64, 48, 36, 32, 24, 16} {
		if mem >= bucket {
			k := family + ":" + memBucket(bucket)
			if rate, ok := streamRateTable[k]; ok {
				return rate
			}
		}
	}

	return streamRateTable["base"]
}

func memBucket(gb int) string {
	switch {
	case gb >= 256:
		return "256"
	case gb >= 192:
		return "192"
	case gb >= 128:
		return "128"
	case gb >= 96:
		return "96"
	case gb >= 64:
		return "64"
	case gb >= 48:
		return "48"
	case gb >= 36:
		return "36"
	case gb >= 32:
		return "32"
	case gb >= 24:
		return "24"
	default:
		return "16"
	}
}

// MonthlyRateToPerSecond converts a monthly micro-USD rate to per-second.
// Uses 30-day month (30 * 24 * 3600 = 2_592_000 seconds).
func MonthlyRateToPerSecond(monthlyMicroUSD int64) int64 {
	const secondsPerMonth int64 = 30 * 24 * 3600
	return monthlyMicroUSD / secondsPerMonth
}

// ProviderStreamState tracks per-provider streaming payment state.
type ProviderStreamState struct {
	LastPaymentTime  time.Time // last time a stream payment was credited
	TotalPaidSession int64     // total micro-USD paid in this connection session
	EligibleSeconds  int64     // total seconds deemed eligible this session
	IneligibleCount  int64     // heartbeats skipped due to ineligibility
}

// StreamEngine manages streaming payments to all connected providers.
type StreamEngine struct {
	mu     sync.Mutex
	states map[string]*ProviderStreamState // providerID → state

	store  store.Store
	logger *slog.Logger

	maxMemoryPressure float64
	enabled           bool
	budgetAccountID   string // the account that funds stream payments (e.g. "stream_budget")
}

// StreamEngineConfig configures the stream payment engine.
type StreamEngineConfig struct {
	Enabled           bool
	MaxMemoryPressure float64
	BudgetAccountID   string // defaults to "stream_budget"
}

// NewStreamEngine creates a new StreamEngine.
func NewStreamEngine(st store.Store, logger *slog.Logger, cfg StreamEngineConfig) *StreamEngine {
	maxMP := cfg.MaxMemoryPressure
	if maxMP <= 0 || maxMP > 1.0 {
		maxMP = DefaultMaxMemoryPressure
	}
	budgetID := cfg.BudgetAccountID
	if budgetID == "" {
		budgetID = "stream_budget"
	}
	return &StreamEngine{
		states:            make(map[string]*ProviderStreamState),
		store:             st,
		logger:            logger,
		maxMemoryPressure: maxMP,
		enabled:           cfg.Enabled,
		budgetAccountID:   budgetID,
	}
}

// IsEnabled returns whether streaming payments are active.
func (se *StreamEngine) IsEnabled() bool {
	return se.enabled
}

// ProcessHeartbeat evaluates a provider's heartbeat for stream payment eligibility
// and credits the appropriate amount. Returns the micro-USD amount paid (0 if ineligible).
//
// Parameters:
//   - providerID: coordinator-assigned UUID
//   - accountID: linked Privy account (empty = not linked, payment deferred)
//   - hw: provider hardware info (for rate lookup)
//   - metrics: live system metrics from the heartbeat
//   - status: heartbeat status ("idle", "serving")
func (se *StreamEngine) ProcessHeartbeat(
	providerID string,
	accountID string,
	hw protocol.Hardware,
	metrics protocol.SystemMetrics,
	status string,
) int64 {
	if !se.enabled {
		return 0
	}

	// Unlinked providers can't receive payments.
	if accountID == "" {
		return 0
	}

	se.mu.Lock()
	state, ok := se.states[providerID]
	if !ok {
		state = &ProviderStreamState{
			LastPaymentTime: time.Now(),
		}
		se.states[providerID] = state
		se.mu.Unlock()
		return 0 // first heartbeat initializes tracking, no payment
	}
	se.mu.Unlock()

	// Check eligibility.
	eligible, reason := se.checkEligibility(metrics, status)
	if !eligible {
		se.mu.Lock()
		state.IneligibleCount++
		se.mu.Unlock()
		se.logger.Debug("stream payment skipped",
			"provider_id", providerID,
			"reason", reason,
		)
		return 0
	}

	now := time.Now()
	elapsed := now.Sub(state.LastPaymentTime)

	// Enforce minimum interval to prevent double-pay.
	if elapsed < MinPaymentInterval {
		return 0
	}

	// Cap elapsed time to prevent large retroactive payments.
	if elapsed > MaxPaymentGap {
		elapsed = MaxPaymentGap
	}

	// Calculate payment.
	rate := LookupStreamRate(hw)
	perSecond := MonthlyRateToPerSecond(rate.MonthlyMicroUSD)
	payment := perSecond * int64(elapsed.Seconds())

	if payment <= 0 {
		return 0
	}

	// Credit the provider's account via the ledger.
	if err := se.store.CreditProviderAccount(&store.ProviderEarning{
		AccountID:      accountID,
		ProviderID:     providerID,
		ProviderKey:    "", // stream payments don't have a per-key association
		JobID:          "stream:" + providerID,
		Model:          "stream_payment",
		AmountMicroUSD: payment,
		CreatedAt:      now,
	}); err != nil {
		se.logger.Error("failed to credit stream payment",
			"provider_id", providerID,
			"account_id", accountID,
			"amount_micro_usd", payment,
			"error", err,
		)
		return 0
	}

	se.mu.Lock()
	state.LastPaymentTime = now
	state.TotalPaidSession += payment
	state.EligibleSeconds += int64(elapsed.Seconds())
	se.mu.Unlock()

	se.logger.Debug("stream payment credited",
		"provider_id", providerID,
		"account_id", accountID,
		"amount_micro_usd", payment,
		"elapsed_seconds", int64(elapsed.Seconds()),
		"monthly_rate_usd", float64(rate.MonthlyMicroUSD)/1_000_000,
		"rate_desc", rate.Description,
	)

	return payment
}

// checkEligibility determines if a provider heartbeat qualifies for payment.
func (se *StreamEngine) checkEligibility(
	metrics protocol.SystemMetrics,
	status string,
) (bool, string) {
	// Must be online (idle or serving).
	if status != "idle" && status != "serving" {
		return false, "status_not_active"
	}

	// Memory pressure must be below threshold.
	if metrics.MemoryPressure >= se.maxMemoryPressure {
		return false, "memory_pressure_high"
	}

	// Thermal state must not be critical.
	if metrics.ThermalState == "critical" {
		return false, "thermal_critical"
	}

	return true, ""
}

// OnProviderDisconnect cleans up stream state for a disconnected provider.
// The caller should invoke this when a provider WebSocket closes.
func (se *StreamEngine) OnProviderDisconnect(providerID string) {
	se.mu.Lock()
	defer se.mu.Unlock()

	if state, ok := se.states[providerID]; ok {
		if state.TotalPaidSession > 0 {
			se.logger.Info("stream session ended",
				"provider_id", providerID,
				"total_paid_micro_usd", state.TotalPaidSession,
				"eligible_seconds", state.EligibleSeconds,
				"ineligible_heartbeats", state.IneligibleCount,
			)
		}
		delete(se.states, providerID)
	}
}

// GetProviderStreamState returns a copy of the stream state for a provider.
// Returns nil if the provider has no active stream state.
func (se *StreamEngine) GetProviderStreamState(providerID string) *ProviderStreamState {
	se.mu.Lock()
	defer se.mu.Unlock()

	state, ok := se.states[providerID]
	if !ok {
		return nil
	}
	cp := *state
	return &cp
}

// StreamStats returns aggregate statistics across all active stream sessions.
type StreamStats struct {
	ActiveProviders int   `json:"active_providers"`
	TotalPaidToday  int64 `json:"total_paid_today_micro_usd"`
}

// Stats returns current streaming payment statistics.
func (se *StreamEngine) Stats() StreamStats {
	se.mu.Lock()
	defer se.mu.Unlock()

	stats := StreamStats{
		ActiveProviders: len(se.states),
	}
	for _, state := range se.states {
		stats.TotalPaidToday += state.TotalPaidSession
	}
	return stats
}
