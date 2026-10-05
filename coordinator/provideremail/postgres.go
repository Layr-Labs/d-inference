package provideremail

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
)

// Rank before filtering ownership or recency. first_seen is only an upper bound
// for legacy registrations without a recorded origin: if one could be newer,
// select it and exclude the machine below rather than resurrect a previous owner.
const audienceSQL = `WITH sessions AS (
 SELECT s.*, NULLIF(s.observation->>'registered_at','0001-01-01T00:00:00Z')::timestamptz AS registered_at
 FROM darkbloom_machine_sessions s
 JOIN darkbloom_machines m ON m.id=s.machine_id AND m.merged_into IS NULL
), latest AS (
 SELECT DISTINCT ON (s.machine_id)
  s.machine_id, s.account_id, s.last_seen, s.observation, s.registered_at, s.first_seen,
  COUNT(*) OVER (PARTITION BY s.machine_id, COALESCE(s.registered_at,s.first_seen)) AS same_order
 FROM sessions s
 ORDER BY s.machine_id, COALESCE(s.registered_at,s.first_seen) DESC,
  (s.registered_at IS NULL) DESC, s.session_id DESC
)
SELECT l.machine_id, l.account_id, COALESCE(u.email,''), l.last_seen, l.observation,
 l.registered_at IS NOT NULL AND l.registered_at <= l.first_seen AND l.same_order=1
FROM latest l LEFT JOIN users u ON u.account_id=l.account_id
ORDER BY l.machine_id`

// ReadSnapshot deliberately does not construct store.PostgresStore, whose
// constructor runs migrations. Every query uses one read-only repeatable-read
// transaction, with database and wall-clock timeouts; a read replica is enough.
func ReadSnapshot(ctx context.Context, databaseURL string, activeDays int) (Snapshot, error) {
	var s Snapshot
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	cfg, err := pgx.ParseConfig(databaseURL)
	if err != nil {
		return s, fmt.Errorf("invalid provider email database configuration")
	}
	cfg.ConnectTimeout = 5 * time.Second
	cfg.RuntimeParams["default_transaction_read_only"] = "on"
	cfg.RuntimeParams["statement_timeout"] = "15000"
	cfg.RuntimeParams["lock_timeout"] = "2000"
	cfg.RuntimeParams["application_name"] = "darkbloom-provider-emails"
	conn, err := pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		return s, fmt.Errorf("connect to provider email database failed (check credentials and connectivity)")
	}
	defer conn.Close(context.Background())
	tx, err := conn.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return s, fmt.Errorf("begin read-only snapshot: %w", err)
	}
	defer tx.Rollback(context.Background())
	if err := tx.QueryRow(ctx, `SELECT transaction_timestamp()`).Scan(&s.CapturedAt); err != nil {
		return s, err
	}
	if err := tx.QueryRow(ctx, `SELECT COUNT(*) FROM providers p WHERE p.last_seen >= $1
 AND NOT EXISTS (SELECT 1 FROM darkbloom_machine_sessions s WHERE s.session_id=p.id)`, s.CapturedAt.AddDate(0, 0, -activeDays)).Scan(&s.UntrackedSessions); err != nil {
		return s, fmt.Errorf("inventory coverage: %w", err)
	}
	rows, err := tx.Query(ctx, audienceSQL)
	if err != nil {
		return s, fmt.Errorf("read provider inventory: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var m Machine
		var raw []byte
		var registrationKnown bool
		if err := rows.Scan(&m.ID, &m.AccountID, &m.Email, &m.LastSeen, &raw, &registrationKnown); err != nil {
			return s, err
		}
		if !registrationKnown {
			s.UnknownRegistration++
			continue
		}
		var observation struct {
			Source       string    `json:"source"`
			Version      string    `json:"version"`
			OSVersion    string    `json:"os_version"`
			OSSource     string    `json:"os_source"`
			OSObservedAt time.Time `json:"os_observed_at"`
		}
		if err := json.Unmarshal(raw, &observation); err != nil {
			return s, fmt.Errorf("invalid machine inventory observation")
		}
		m.Source, m.ProviderVersion = observation.Source, observation.Version
		m.OSVersion, m.OSSource, m.OSObservedAt = observation.OSVersion, observation.OSSource, observation.OSObservedAt
		s.Machines = append(s.Machines, m)
	}
	if err := rows.Err(); err != nil {
		return s, err
	}
	return s, tx.Commit(ctx)
}
