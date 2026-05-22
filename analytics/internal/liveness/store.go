// Package liveness exposes the read side of provider liveness analytics:
// per-provider uptime/sessions/heartbeats, fleet-wide availability, and a
// reliability shortlist suitable for job-aware scheduling.
//
// The data is populated by the coordinator's liveness writer + features
// rollup worker — this package only reads. It mirrors the leaderboard
// package's shape (Service over Store with memory + postgres impls).
package liveness

import (
	"context"
	"encoding/json"
	"time"
)

// Defaults for endpoint inputs.
const (
	DefaultLimit    = 50
	MaxLimit        = 500
	DefaultWindow7d = "7d"
)

// Window is a coarse retrospective period selector reused across endpoints.
type Window string

const (
	Window24h Window = "24h"
	Window7d  Window = "7d"
	Window30d Window = "30d"
)

// ParseWindow validates a window string. Empty string defaults to 7d.
func ParseWindow(raw string) (Window, error) {
	switch raw {
	case "", "7d":
		return Window7d, nil
	case "24h":
		return Window24h, nil
	case "30d":
		return Window30d, nil
	}
	return "", &ParseError{Field: "window", Value: raw, Allowed: "24h, 7d, 30d"}
}

// Duration converts a Window to a time.Duration.
func (w Window) Duration() time.Duration {
	switch w {
	case Window24h:
		return 24 * time.Hour
	case Window30d:
		return 30 * 24 * time.Hour
	default:
		return 7 * 24 * time.Hour
	}
}

// ParseError is a structured invalid-input error the httpapi layer surfaces
// as 400 Bad Request.
type ParseError struct {
	Field   string
	Value   string
	Allowed string
}

func (e *ParseError) Error() string {
	return e.Field + " must be one of: " + e.Allowed + ", got " + e.Value
}

// Summary is the response shape for GET /v1/providers/:id/liveness.
type Summary struct {
	Alias                      string    `json:"alias"`
	WindowDays                 int       `json:"window_days"`
	UptimePct                  float64   `json:"uptime_pct"`
	SessionsCount              int       `json:"sessions_count"`
	MTBFSeconds                int64     `json:"mtbf_seconds"`
	MedianSessionSeconds       int64     `json:"median_session_seconds"`
	P10SessionSeconds          int64     `json:"p10_session_seconds"`
	P90SessionSeconds          int64     `json:"p90_session_seconds"`
	PStays4h                   float64   `json:"p_stays_4h"`
	PStays8h                   float64   `json:"p_stays_8h"`
	LastDisconnectAt           time.Time `json:"last_disconnect_at,omitempty"`
	LastSessionDurationSeconds int64     `json:"last_session_duration_seconds"`
	HourlyAvailability         []float64 `json:"hourly_availability,omitempty"` // 168-element 7×24 row-major
	DisconnectReasons          map[string]int `json:"disconnect_reasons,omitempty"`
	UpdatedAt                  time.Time `json:"updated_at"`
}

// SessionEntry is one row in the /sessions endpoint response. Provider ID is
// already pseudonymized by the time it reaches the consumer.
type SessionEntry struct {
	ID                int64     `json:"id"`
	Alias             string    `json:"alias"`
	ConnectedAt       time.Time `json:"connected_at"`
	DisconnectedAt   time.Time `json:"disconnected_at,omitempty"`
	DisconnectReason string    `json:"disconnect_reason,omitempty"`
	DurationSeconds  int64     `json:"duration_seconds"`
	RequestsServed   int64     `json:"requests_served"`
	TokensGenerated  int64     `json:"tokens_generated"`
}

// HeartbeatEntry is one row in the /heartbeats endpoint response.
type HeartbeatEntry struct {
	Alias          string    `json:"alias"`
	At             time.Time `json:"at"`
	Status         string    `json:"status"`
	MemoryPressure float32   `json:"memory_pressure"`
	CPUUsage       float32   `json:"cpu_usage"`
	ThermalState   string    `json:"thermal_state"`
}

// ReliabilityEntry is one row in the /providers/reliability shortlist.
type ReliabilityEntry struct {
	Alias                string  `json:"alias"`
	UptimePct            float64 `json:"uptime_pct"`
	SessionsCount        int     `json:"sessions_count"`
	MedianSessionSeconds int64   `json:"median_session_seconds"`
	PStays4h             float64 `json:"p_stays_4h"`
	PStays8h             float64 `json:"p_stays_8h"`
}

// FleetAvailability is the response for /v1/network/availability. It returns
// distributional rather than per-provider info to keep things aggregate.
type FleetAvailability struct {
	WindowDays         int     `json:"window_days"`
	Providers          int     `json:"providers"`
	MeanUptimePct      float64 `json:"mean_uptime_pct"`
	P10UptimePct       float64 `json:"p10_uptime_pct"`
	P50UptimePct       float64 `json:"p50_uptime_pct"`
	P90UptimePct       float64 `json:"p90_uptime_pct"`
	HighlyReliable     int     `json:"highly_reliable"` // count of providers with uptime ≥ 0.95
}

// ReliabilityFilterInput mirrors store.ReliabilityFilter with parsed types.
type ReliabilityFilterInput struct {
	MinUptimePct float64
	MinPStays4h  float64
	MinPStays8h  float64
	Limit        int
}

// Aliaser maps internal IDs to opaque public aliases. Reuses the package the
// existing leaderboard endpoints use; we never return provider_id directly.
type Aliaser interface {
	Alias(kind, stableID string) string
}

// Store is the data-access surface this package consumes. Implementations
// (memory, postgres) live alongside.
type Store interface {
	Backend() string
	Ping(ctx context.Context) error
	Close()

	GetReliabilityFeatures(ctx context.Context, providerID string) (*ReliabilityRow, error)
	ListRecentSessions(ctx context.Context, providerID string, since time.Time, limit int) ([]SessionRow, error)
	ListRecentHeartbeats(ctx context.Context, providerID string, since time.Time, limit int) ([]HeartbeatRow, error)
	ListReliable(ctx context.Context, filter ReliabilityFilterInput) ([]ReliabilityRow, error)
	FleetSummary(ctx context.Context) (FleetAvailability, error)
}

// ReliabilityRow mirrors store.ReliabilityFeatures with JSON parsed.
type ReliabilityRow struct {
	ProviderID                 string
	UpdatedAt                  time.Time
	WindowDays                 int
	UptimePct                  float64
	SessionsCount              int
	MTBFSeconds                int64
	MedianSessionSeconds       int64
	P10SessionSeconds          int64
	P90SessionSeconds          int64
	HourlyAvailability         []float64
	DisconnectReasons          map[string]int
	PStays4h                   float64
	PStays8h                   float64
	LastDisconnectAt           time.Time
	LastSessionDurationSeconds int64
}

// SessionRow is one provider_sessions row, schema-shaped.
type SessionRow struct {
	ID               int64
	ProviderID       string
	ConnectedAt      time.Time
	DisconnectedAt   time.Time
	DisconnectReason string
	RequestsServed   int64
	TokensGenerated  int64
}

// HeartbeatRow is one provider_heartbeats row.
type HeartbeatRow struct {
	ProviderID     string
	At             time.Time
	Status         string
	MemoryPressure float32
	CPUUsage       float32
	ThermalState   string
}

// parseReliabilityJSON safely decodes the two JSONB columns into Go values.
// Either may be absent / empty.
func parseReliabilityJSON(hourly, reasons []byte) ([]float64, map[string]int) {
	var (
		availability  []float64
		reasonHist    map[string]int
	)
	if len(hourly) > 0 {
		_ = json.Unmarshal(hourly, &availability)
	}
	if len(reasons) > 0 {
		_ = json.Unmarshal(reasons, &reasonHist)
	}
	return availability, reasonHist
}
