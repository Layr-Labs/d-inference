package store

import (
	"context"
	"errors"
	"time"
)

func (s *PostgresStore) GetMachineRewardBindings(ctx context.Context, sessions []string) (map[string]MachineRewardBinding, error) {
	sessions, err := machineRewardBatch(sessions)
	if err != nil {
		return nil, err
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	out := make(map[string]MachineRewardBinding, len(sessions))
	if len(sessions) == 0 {
		return out, nil
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	rows, err := s.pool.Query(ctx, `WITH RECURSIVE selected AS (
	 SELECT s.session_id,s.machine_id,s.account_id FROM darkbloom_machine_sessions s
	 JOIN darkbloom_machines m ON m.id=s.machine_id AND m.merged_into IS NULL
	 WHERE s.session_id=ANY($1::text[]) AND s.account_id<>'' AND m.assurance<>'provisional'
	), ancestors AS (
	 SELECT DISTINCT machine_id AS canonical,machine_id AS id,0 AS depth FROM selected
	 UNION ALL SELECT a.canonical,m.id,a.depth+1 FROM darkbloom_machines m JOIN ancestors a ON m.merged_into=a.id WHERE a.depth<100
	)
	SELECT s.session_id,s.machine_id,s.account_id,ARRAY(SELECT id FROM ancestors a WHERE a.canonical=s.machine_id ORDER BY id) FROM selected s`, sessions)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var session string
		var b MachineRewardBinding
		if err := rows.Scan(&session, &b.MachineID, &b.AccountID, &b.MachineAliases); err != nil {
			return nil, err
		}
		out[session] = b
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return out, nil
}

func (s *PostgresStore) SumProviderEarningsByKeysForAccount(ctx context.Context, account string, keys []string, start, end time.Time) (int64, error) {
	keys, err := machineRewardBatch(keys)
	if err != nil {
		return 0, err
	}
	if err := ctx.Err(); err != nil {
		return 0, err
	}
	if account == "" {
		return 0, errors.New("machine_reward_account_required")
	}
	if len(keys) == 0 {
		return 0, nil
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	var total int64
	err = s.pool.QueryRow(ctx, `SELECT COALESCE(SUM(amount_micro_usd),0) FROM provider_earnings
	 WHERE account_id=$1 AND provider_key=ANY($2::text[]) AND created_at>=$3 AND created_at<$4
	 AND amount_micro_usd>0 AND model<>'base_reward'`, account, keys, start, end).Scan(&total)
	return total, err
}
