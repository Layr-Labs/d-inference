package liveness

import (
	"context"
	"sort"
	"time"
)

// Service composes the read store and the pseudonym aliaser. Construct one
// via NewService and pass it to the httpapi handler. Cheap to copy.
type Service struct {
	store   Store
	aliaser Aliaser
	now     func() time.Time
}

func NewService(store Store, aliaser Aliaser, now func() time.Time) *Service {
	if now == nil {
		now = time.Now
	}
	return &Service{store: store, aliaser: aliaser, now: now}
}

func (s *Service) Backend() string                 { return s.store.Backend() }
func (s *Service) Ping(ctx context.Context) error  { return s.store.Ping(ctx) }
func (s *Service) Close()                          { s.store.Close() }

// ProviderSummary returns the per-provider reliability summary. Returns
// (nil, nil) when we have no rollup row for this provider yet.
func (s *Service) ProviderSummary(ctx context.Context, providerID string) (*Summary, error) {
	row, err := s.store.GetReliabilityFeatures(ctx, providerID)
	if err != nil {
		return nil, err
	}
	if row == nil {
		return nil, nil
	}
	return s.toSummary(row), nil
}

// ProviderSessions returns recent sessions for one provider.
func (s *Service) ProviderSessions(ctx context.Context, providerID string, window Window, limit int) ([]SessionEntry, error) {
	rows, err := s.store.ListRecentSessions(ctx, providerID, s.windowSince(window), clampLimit(limit))
	if err != nil {
		return nil, err
	}
	out := make([]SessionEntry, 0, len(rows))
	now := s.now()
	for _, r := range rows {
		end := r.DisconnectedAt
		if end.IsZero() {
			end = now
		}
		out = append(out, SessionEntry{
			ID:               r.ID,
			Alias:            s.aliaser.Alias("provider", r.ProviderID),
			ConnectedAt:      r.ConnectedAt,
			DisconnectedAt:   r.DisconnectedAt,
			DisconnectReason: r.DisconnectReason,
			DurationSeconds:  int64(end.Sub(r.ConnectedAt).Seconds()),
			RequestsServed:   r.RequestsServed,
			TokensGenerated:  r.TokensGenerated,
		})
	}
	return out, nil
}

// ProviderHeartbeats returns recent heartbeat samples for one provider.
func (s *Service) ProviderHeartbeats(ctx context.Context, providerID string, window Window, limit int) ([]HeartbeatEntry, error) {
	rows, err := s.store.ListRecentHeartbeats(ctx, providerID, s.windowSince(window), clampLimit(limit))
	if err != nil {
		return nil, err
	}
	out := make([]HeartbeatEntry, 0, len(rows))
	for _, r := range rows {
		out = append(out, HeartbeatEntry{
			Alias:          s.aliaser.Alias("provider", r.ProviderID),
			At:             r.At,
			Status:         r.Status,
			MemoryPressure: r.MemoryPressure,
			CPUUsage:       r.CPUUsage,
			ThermalState:   r.ThermalState,
		})
	}
	return out, nil
}

// ReliableProviders returns the providers meeting a reliability bar,
// ordered by uptime_pct desc.
func (s *Service) ReliableProviders(ctx context.Context, filter ReliabilityFilterInput) ([]ReliabilityEntry, error) {
	if filter.Limit <= 0 {
		filter.Limit = DefaultLimit
	}
	if filter.Limit > MaxLimit {
		filter.Limit = MaxLimit
	}
	rows, err := s.store.ListReliable(ctx, filter)
	if err != nil {
		return nil, err
	}
	out := make([]ReliabilityEntry, 0, len(rows))
	for _, r := range rows {
		out = append(out, ReliabilityEntry{
			Alias:                s.aliaser.Alias("provider", r.ProviderID),
			UptimePct:            r.UptimePct,
			SessionsCount:        r.SessionsCount,
			MedianSessionSeconds: r.MedianSessionSeconds,
			PStays4h:             r.PStays4h,
			PStays8h:             r.PStays8h,
		})
	}
	return out, nil
}

// FleetAvailability returns aggregate distributional stats over all providers
// with reliability features.
func (s *Service) FleetAvailability(ctx context.Context) (FleetAvailability, error) {
	return s.store.FleetSummary(ctx)
}

// toSummary converts the row into the API response, aliasing the provider id.
func (s *Service) toSummary(r *ReliabilityRow) *Summary {
	return &Summary{
		Alias:                      s.aliaser.Alias("provider", r.ProviderID),
		WindowDays:                 r.WindowDays,
		UptimePct:                  r.UptimePct,
		SessionsCount:              r.SessionsCount,
		MTBFSeconds:                r.MTBFSeconds,
		MedianSessionSeconds:       r.MedianSessionSeconds,
		P10SessionSeconds:          r.P10SessionSeconds,
		P90SessionSeconds:          r.P90SessionSeconds,
		PStays4h:                   r.PStays4h,
		PStays8h:                   r.PStays8h,
		LastDisconnectAt:           r.LastDisconnectAt,
		LastSessionDurationSeconds: r.LastSessionDurationSeconds,
		HourlyAvailability:         r.HourlyAvailability,
		DisconnectReasons:          r.DisconnectReasons,
		UpdatedAt:                  r.UpdatedAt,
	}
}

func (s *Service) windowSince(w Window) time.Time {
	return s.now().Add(-w.Duration())
}

func clampLimit(n int) int {
	if n <= 0 {
		return DefaultLimit
	}
	if n > MaxLimit {
		return MaxLimit
	}
	return n
}

// computeFleet derives the FleetAvailability struct from a list of rows.
// Pulled out so both the memory and postgres impls can share the math.
func computeFleet(rows []ReliabilityRow) FleetAvailability {
	if len(rows) == 0 {
		return FleetAvailability{WindowDays: 14}
	}
	uptimes := make([]float64, len(rows))
	var sum float64
	highlyReliable := 0
	for i, r := range rows {
		uptimes[i] = r.UptimePct
		sum += r.UptimePct
		if r.UptimePct >= 0.95 {
			highlyReliable++
		}
	}
	sort.Float64s(uptimes)
	return FleetAvailability{
		WindowDays:     rows[0].WindowDays,
		Providers:      len(rows),
		MeanUptimePct:  sum / float64(len(rows)),
		P10UptimePct:   uptimes[percentileIdx(len(rows), 0.10)],
		P50UptimePct:   uptimes[percentileIdx(len(rows), 0.50)],
		P90UptimePct:   uptimes[percentileIdx(len(rows), 0.90)],
		HighlyReliable: highlyReliable,
	}
}

func percentileIdx(n int, p float64) int {
	if n <= 0 {
		return 0
	}
	idx := int(p * float64(n-1))
	if idx < 0 {
		idx = 0
	}
	if idx >= n {
		idx = n - 1
	}
	return idx
}
