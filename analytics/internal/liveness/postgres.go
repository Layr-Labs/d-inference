package liveness

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// PostgresStore reads liveness data from the coordinator-managed schema.
// Connect with a read-only role (see analytics/README.md) — this package
// never writes. Reads target a replica when ANALYTICS_DATABASE_URL points
// at one.
type PostgresStore struct {
	pool *pgxpool.Pool
}

func NewPostgresStore(ctx context.Context, databaseURL string) (*PostgresStore, error) {
	cfg, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		return nil, fmt.Errorf("liveness: parse postgres config: %w", err)
	}
	if cfg.MaxConns <= 0 || cfg.MaxConns > 8 {
		// Per plan safeguard: cap analytics pool small so a runaway query
		// can't starve the operational DB's pool.
		cfg.MaxConns = 8
	}
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("liveness: connect postgres: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("liveness: ping postgres: %w", err)
	}
	return &PostgresStore{pool: pool}, nil
}

func (s *PostgresStore) Backend() string               { return "postgres" }
func (s *PostgresStore) Ping(ctx context.Context) error { return s.pool.Ping(ctx) }
func (s *PostgresStore) Close()                         { s.pool.Close() }

func (s *PostgresStore) GetReliabilityFeatures(ctx context.Context, providerID string) (*ReliabilityRow, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	var (
		row      ReliabilityRow
		lastDisc *time.Time
		hourly   []byte
		reasons  []byte
	)
	err := s.pool.QueryRow(ctx,
		`SELECT provider_id, updated_at, window_days, uptime_pct, sessions_count,
		        mtbf_seconds, median_session_seconds, p10_session_seconds, p90_session_seconds,
		        hourly_availability, disconnect_reasons, p_stays_4h, p_stays_8h,
		        last_disconnect_at, last_session_duration_seconds
		   FROM provider_reliability_features WHERE provider_id = $1`,
		providerID,
	).Scan(
		&row.ProviderID, &row.UpdatedAt, &row.WindowDays, &row.UptimePct, &row.SessionsCount,
		&row.MTBFSeconds, &row.MedianSessionSeconds, &row.P10SessionSeconds, &row.P90SessionSeconds,
		&hourly, &reasons, &row.PStays4h, &row.PStays8h,
		&lastDisc, &row.LastSessionDurationSeconds,
	)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, fmt.Errorf("liveness: get reliability features: %w", err)
	}
	if lastDisc != nil {
		row.LastDisconnectAt = *lastDisc
	}
	row.HourlyAvailability, row.DisconnectReasons = parseReliabilityJSON(hourly, reasons)
	return &row, nil
}

func (s *PostgresStore) ListRecentSessions(ctx context.Context, providerID string, since time.Time, limit int) ([]SessionRow, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT id, provider_id, connected_at, disconnected_at,
		        COALESCE(disconnect_reason,''),
		        requests_served, tokens_generated
		   FROM provider_sessions
		  WHERE provider_id = $1 AND connected_at >= $2
		  ORDER BY connected_at DESC LIMIT $3`,
		providerID, since, limit,
	)
	if err != nil {
		return nil, fmt.Errorf("liveness: list recent sessions: %w", err)
	}
	defer rows.Close()

	var out []SessionRow
	for rows.Next() {
		var (
			r      SessionRow
			discAt *time.Time
		)
		if err := rows.Scan(
			&r.ID, &r.ProviderID, &r.ConnectedAt, &discAt,
			&r.DisconnectReason, &r.RequestsServed, &r.TokensGenerated,
		); err != nil {
			return nil, fmt.Errorf("liveness: scan session: %w", err)
		}
		if discAt != nil {
			r.DisconnectedAt = *discAt
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

func (s *PostgresStore) ListRecentHeartbeats(ctx context.Context, providerID string, since time.Time, limit int) ([]HeartbeatRow, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT provider_id, at, status, memory_pressure, cpu_usage, thermal_state
		   FROM provider_heartbeats
		  WHERE provider_id = $1 AND at >= $2
		  ORDER BY at DESC LIMIT $3`,
		providerID, since, limit,
	)
	if err != nil {
		return nil, fmt.Errorf("liveness: list recent heartbeats: %w", err)
	}
	defer rows.Close()

	var out []HeartbeatRow
	for rows.Next() {
		var r HeartbeatRow
		if err := rows.Scan(
			&r.ProviderID, &r.At, &r.Status, &r.MemoryPressure, &r.CPUUsage, &r.ThermalState,
		); err != nil {
			return nil, fmt.Errorf("liveness: scan heartbeat: %w", err)
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

func (s *PostgresStore) ListReliable(ctx context.Context, filter ReliabilityFilterInput) ([]ReliabilityRow, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	limit := filter.Limit
	if limit <= 0 || limit > MaxLimit {
		limit = DefaultLimit
	}
	rows, err := s.pool.Query(ctx,
		`SELECT provider_id, updated_at, window_days, uptime_pct, sessions_count,
		        mtbf_seconds, median_session_seconds, p10_session_seconds, p90_session_seconds,
		        hourly_availability, disconnect_reasons, p_stays_4h, p_stays_8h,
		        last_disconnect_at, last_session_duration_seconds
		   FROM provider_reliability_features
		  WHERE uptime_pct >= $1 AND p_stays_4h >= $2 AND p_stays_8h >= $3
		  ORDER BY uptime_pct DESC, provider_id ASC
		  LIMIT $4`,
		filter.MinUptimePct, filter.MinPStays4h, filter.MinPStays8h, limit,
	)
	if err != nil {
		return nil, fmt.Errorf("liveness: list reliable: %w", err)
	}
	defer rows.Close()

	var out []ReliabilityRow
	for rows.Next() {
		var (
			row      ReliabilityRow
			lastDisc *time.Time
			hourly   []byte
			reasons  []byte
		)
		if err := rows.Scan(
			&row.ProviderID, &row.UpdatedAt, &row.WindowDays, &row.UptimePct, &row.SessionsCount,
			&row.MTBFSeconds, &row.MedianSessionSeconds, &row.P10SessionSeconds, &row.P90SessionSeconds,
			&hourly, &reasons, &row.PStays4h, &row.PStays8h,
			&lastDisc, &row.LastSessionDurationSeconds,
		); err != nil {
			return nil, fmt.Errorf("liveness: scan reliability features: %w", err)
		}
		if lastDisc != nil {
			row.LastDisconnectAt = *lastDisc
		}
		row.HourlyAvailability, row.DisconnectReasons = parseReliabilityJSON(hourly, reasons)
		out = append(out, row)
	}
	return out, rows.Err()
}

func (s *PostgresStore) FleetSummary(ctx context.Context) (FleetAvailability, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT provider_id, uptime_pct, window_days FROM provider_reliability_features`,
	)
	if err != nil {
		return FleetAvailability{}, fmt.Errorf("liveness: fleet summary: %w", err)
	}
	defer rows.Close()

	var collected []ReliabilityRow
	for rows.Next() {
		var r ReliabilityRow
		if err := rows.Scan(&r.ProviderID, &r.UptimePct, &r.WindowDays); err != nil {
			return FleetAvailability{}, fmt.Errorf("liveness: scan fleet row: %w", err)
		}
		collected = append(collected, r)
	}
	if err := rows.Err(); err != nil {
		return FleetAvailability{}, err
	}
	return computeFleet(collected), nil
}
