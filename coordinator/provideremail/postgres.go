package provideremail

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
)

// Rank before filtering by account, recency or source: a newer anonymous or
// historical session must not resurrect a previous owner's membership. Inventory
// merges rewrite machine_id on all sessions; first_seen orders registrations so
// a delayed disconnect/heartbeat on an older session cannot reclaim ownership.
const audienceSQL = `WITH latest AS (
 SELECT DISTINCT ON (s.machine_id)
  s.machine_id, s.account_id, s.last_seen, s.observation
 FROM darkbloom_machine_sessions s
 JOIN darkbloom_machines m ON m.id=s.machine_id AND m.merged_into IS NULL
 ORDER BY s.machine_id, s.first_seen DESC, s.last_seen DESC, s.session_id DESC
)
SELECT l.machine_id, l.account_id, COALESCE(u.email,''), l.last_seen, l.observation
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
		if err := rows.Scan(&m.ID, &m.AccountID, &m.Email, &m.LastSeen, &raw); err != nil {
			return s, err
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
