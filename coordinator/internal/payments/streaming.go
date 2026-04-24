package payments

import (
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/eigeninference/coordinator/internal/store"
)

// StreamTracker manages per-provider streaming payments. Providers earn a
// fixed monthly rate (streamed per-minute) while they are online and have
// sufficient memory available for inference. The tracker is goroutine-safe.
type StreamTracker struct {
	mu       sync.Mutex
	store    store.Store
	logger   *slog.Logger
	sessions map[string]*streamSession // provider ID → active session
}

type streamSession struct {
	ProviderID   string
	ProviderKey  string // X25519 public key (stable hardware ID)
	AccountID    string
	MemoryGB     int
	BandwidthGBs float64
	RatePerMin   int64     // micro-USD per minute
	LastAccrual  time.Time // last time we accrued earnings
	Accrued      int64     // micro-USD accrued since last flush
	Flushed      int64     // micro-USD already flushed to store
}

// MinStreamMemoryGB is the minimum unified memory to qualify for streaming payments.
const MinStreamMemoryGB = 32

// StreamRate returns the monthly rate in micro-USD based on memory and bandwidth.
// The rate is the sum of a memory base (what models can run) and a bandwidth
// bonus (how fast inference runs). Returns 0 if the machine doesn't qualify.
//
// Memory base ($6–$12):  determines max model size
// Bandwidth bonus ($4–$8): determines decode tokens/sec
// Total range: $10–$20/month
func StreamRate(memoryGB int, bandwidthGBs float64) int64 {
	base := memoryBase(memoryGB)
	if base == 0 {
		return 0
	}
	return base + bandwidthBonus(bandwidthGBs)
}

func memoryBase(memoryGB int) int64 {
	switch {
	case memoryGB >= 128:
		return 12_000_000 // $12
	case memoryGB >= 96:
		return 10_000_000 // $10
	case memoryGB >= 64:
		return 9_000_000 // $9
	case memoryGB >= 48:
		return 7_000_000 // $7
	case memoryGB >= MinStreamMemoryGB:
		return 6_000_000 // $6
	default:
		return 0
	}
}

func bandwidthBonus(bandwidthGBs float64) int64 {
	switch {
	case bandwidthGBs >= 700:
		return 8_000_000 // $8 — Ultra chips (800+ GB/s)
	case bandwidthGBs >= 500:
		return 7_000_000 // $7 — M4 Max (546 GB/s)
	case bandwidthGBs >= 350:
		return 6_000_000 // $6 — M3 Max 40-core (400 GB/s)
	case bandwidthGBs >= 200:
		return 5_000_000 // $5 — M3/M4 Pro, M3 Max 30-core (200-300 GB/s)
	default:
		return 4_000_000 // $4 — M3 Pro (150 GB/s)
	}
}

// StreamRatePerMin converts a monthly rate to per-minute micro-USD.
// Assumes 30-day months (43200 minutes).
func StreamRatePerMin(monthlyRate int64) int64 {
	const minutesPerMonth = 30 * 24 * 60 // 43200
	return monthlyRate / minutesPerMonth
}

// NewStreamTracker creates a new StreamTracker backed by the given store.
func NewStreamTracker(st store.Store, logger *slog.Logger) *StreamTracker {
	return &StreamTracker{
		store:    st,
		logger:   logger,
		sessions: make(map[string]*streamSession),
	}
}

// StartSession begins streaming payments for a provider. Called when a
// provider registers with eligible hardware. If a session already exists
// for this provider, it is a no-op.
func (t *StreamTracker) StartSession(providerID, providerKey, accountID, trustLevel string, memoryGB int, bandwidthGBs float64) {
	if accountID == "" {
		return
	}
	if trustLevel != "hardware" && trustLevel != "self_signed" {
		return
	}
	monthlyRate := StreamRate(memoryGB, bandwidthGBs)
	if monthlyRate == 0 {
		return
	}

	t.mu.Lock()
	defer t.mu.Unlock()

	if _, exists := t.sessions[providerID]; exists {
		return
	}

	t.sessions[providerID] = &streamSession{
		ProviderID:   providerID,
		ProviderKey:  providerKey,
		AccountID:    accountID,
		MemoryGB:     memoryGB,
		BandwidthGBs: bandwidthGBs,
		RatePerMin:   StreamRatePerMin(monthlyRate),
		LastAccrual:  time.Now(),
	}

	t.logger.Info("stream session started",
		"provider_id", providerID,
		"memory_gb", memoryGB,
		"bandwidth_gbs", bandwidthGBs,
		"monthly_rate_usd", fmt.Sprintf("%.2f", float64(monthlyRate)/1_000_000),
		"rate_per_min_micro_usd", StreamRatePerMin(monthlyRate),
	)
}

// Heartbeat is called on every provider heartbeat. It checks eligibility
// conditions and accrues earnings if the provider qualifies. Returns the
// micro-USD accrued in this tick (0 if ineligible or no active session).
func (t *StreamTracker) Heartbeat(providerID string, memoryPressure float64, thermalState string, hasWarmModel bool) int64 {
	t.mu.Lock()
	defer t.mu.Unlock()

	sess, ok := t.sessions[providerID]
	if !ok {
		return 0
	}

	if !streamEligible(memoryPressure, thermalState, hasWarmModel) {
		sess.LastAccrual = time.Now()
		return 0
	}

	now := time.Now()
	elapsed := now.Sub(sess.LastAccrual)
	if elapsed < 30*time.Second {
		return 0
	}

	minutes := elapsed.Minutes()
	accrual := int64(minutes * float64(sess.RatePerMin))
	if accrual <= 0 {
		return 0
	}

	sess.Accrued += accrual
	sess.LastAccrual = now

	return accrual
}

// streamEligible checks whether a provider qualifies for streaming payment
// based on real-time system metrics.
func streamEligible(memoryPressure float64, thermalState string, hasWarmModel bool) bool {
	if !hasWarmModel {
		return false
	}
	if memoryPressure >= 0.8 {
		return false
	}
	if thermalState == "critical" {
		return false
	}
	return true
}

// FlushAll persists all pending accruals to the store and resets accumulators.
// Called periodically (e.g. every 5 minutes) to batch writes.
func (t *StreamTracker) FlushAll() {
	t.mu.Lock()
	sessions := make([]*streamSession, 0, len(t.sessions))
	for _, sess := range t.sessions {
		if sess.Accrued > 0 {
			sessions = append(sessions, sess)
		}
	}
	// Snapshot and reset accruals under lock, flush outside lock.
	type pending struct {
		sess    *streamSession
		amount  int64
	}
	toFlush := make([]pending, 0, len(sessions))
	for _, sess := range sessions {
		toFlush = append(toFlush, pending{sess: sess, amount: sess.Accrued})
		sess.Flushed += sess.Accrued
		sess.Accrued = 0
	}
	t.mu.Unlock()

	for _, p := range toFlush {
		t.flushSession(p.sess, p.amount)
	}
}

func (t *StreamTracker) flushSession(sess *streamSession, amount int64) {
	ref := fmt.Sprintf("stream:%s:%d", sess.ProviderID, time.Now().UnixNano())

	if err := t.store.CreditProviderAccount(&store.ProviderEarning{
		AccountID:      sess.AccountID,
		ProviderID:     sess.ProviderID,
		ProviderKey:    sess.ProviderKey,
		JobID:          ref,
		Model:          "streaming",
		AmountMicroUSD: amount,
		CreatedAt:      time.Now(),
	}); err != nil {
		t.logger.Error("failed to flush stream earnings",
			"provider_id", sess.ProviderID,
			"account_id", sess.AccountID,
			"amount_micro_usd", amount,
			"error", err,
		)
		return
	}

	t.logger.Debug("stream earnings flushed",
		"provider_id", sess.ProviderID,
		"amount_micro_usd", amount,
		"amount_usd", fmt.Sprintf("%.6f", float64(amount)/1_000_000),
	)
}

// StopSession finalizes streaming for a provider and flushes any remaining
// accrual. Called when a provider disconnects.
func (t *StreamTracker) StopSession(providerID string) {
	t.mu.Lock()
	sess, ok := t.sessions[providerID]
	if !ok {
		t.mu.Unlock()
		return
	}
	remaining := sess.Accrued
	sess.Accrued = 0
	sess.Flushed += remaining
	delete(t.sessions, providerID)
	t.mu.Unlock()

	if remaining > 0 {
		t.flushSession(sess, remaining)
	}

	t.logger.Info("stream session stopped",
		"provider_id", providerID,
		"total_flushed_micro_usd", sess.Flushed,
	)
}

// ActiveSessions returns a snapshot of all active streaming sessions for
// the admin/status API.
func (t *StreamTracker) ActiveSessions() []StreamSessionInfo {
	t.mu.Lock()
	defer t.mu.Unlock()

	out := make([]StreamSessionInfo, 0, len(t.sessions))
	for _, sess := range t.sessions {
		out = append(out, StreamSessionInfo{
			ProviderID:       sess.ProviderID,
			AccountID:        sess.AccountID,
			MemoryGB:         sess.MemoryGB,
			BandwidthGBs:     sess.BandwidthGBs,
			MonthlyRateUSD:   float64(sess.RatePerMin*43200) / 1_000_000,
			AccruedMicroUSD:  sess.Accrued,
			FlushedMicroUSD:  sess.Flushed,
			LastAccrual:      sess.LastAccrual,
		})
	}
	return out
}

// StreamSessionInfo is the public view of an active streaming session.
type StreamSessionInfo struct {
	ProviderID      string    `json:"provider_id"`
	AccountID       string    `json:"account_id,omitempty"`
	MemoryGB        int       `json:"memory_gb"`
	BandwidthGBs    float64   `json:"bandwidth_gbs"`
	MonthlyRateUSD  float64   `json:"monthly_rate_usd"`
	AccruedMicroUSD int64     `json:"accrued_micro_usd"`
	FlushedMicroUSD int64     `json:"flushed_micro_usd"`
	LastAccrual     time.Time `json:"last_accrual"`
}
