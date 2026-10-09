package postgres

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/payments/rewardpolicy"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/jackc/pgx/v5"
)

// Read under the same identity/financial transaction as the receipt. The union
// uses canonical identity rather than a mutable provider key.
func autopilotRewardUptime(ctx context.Context, tx pgx.Tx, machine autopilotRewardMachine, day time.Time) (bool, error) {
	rows, err := tx.Query(ctx, `SELECT p.connected_at,p.last_seen,p.disconnected_at
	 FROM provider_sessions p JOIN darkbloom_machine_sessions s USING(session_id)
	 WHERE s.machine_id=ANY($1::text[]) AND s.account_id=$2 AND p.account_id=$2
	 AND p.connected_at<$4 AND p.last_seen+interval '90 seconds'>$3
	 AND (p.disconnected_at IS NULL OR p.disconnected_at>$3)`, machine.ancestors, machine.account, day, day.AddDate(0, 0, 1))
	if err != nil {
		return false, err
	}
	defer rows.Close()
	var sessions []store.ProviderSession
	for rows.Next() {
		session := store.ProviderSession{ProviderKey: machine.id}
		if err := rows.Scan(&session.ConnectedAt, &session.LastSeen, &session.DisconnectedAt); err != nil {
			return false, err
		}
		sessions = append(sessions, session)
	}
	if err := rows.Err(); err != nil {
		return false, err
	}
	return rewardpolicy.UptimeByProviderKey(sessions, day, day.AddDate(0, 0, 1), 90*time.Second)[machine.id] >= 0.90, nil
}
