package postgres

import (
	"context"
	"errors"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/payments/floorpolicy"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
	"github.com/jackc/pgx/v5"
)

func (s *PostgresStore) SettleAutopilotRewardDay(ctx context.Context, machineID string, day time.Time) (earningsfloor.Settlement, error) {
	now := s.now().UTC().Truncate(time.Microsecond)
	if err := floorpolicy.ValidateDay(day, now); err != nil {
		return earningsfloor.Settlement{}, err
	}
	day = day.UTC()
	tx, machine, pool, err := s.beginAutopilotRewardMachineWrite(ctx, machineID)
	if err != nil {
		return earningsfloor.Settlement{}, err
	}
	defer rollbackErasureTx(tx)
	enrollment, err := ensureAutopilotRewardEnrollment(ctx, tx, machine, pool)
	if err != nil {
		return earningsfloor.Settlement{}, err
	}
	if enrollment == nil {
		return earningsfloor.Settlement{}, store.ErrNotFound
	}
	final, err := finalizedAutopilotRewardDay(ctx, tx, machine, day)
	if err != nil {
		return earningsfloor.Settlement{}, err
	}
	if final != nil {
		if day.Equal(enrollment.NextDay) {
			if err := advanceAutopilotRewardDay(ctx, tx, enrollment.MachineID, day); err != nil {
				return earningsfloor.Settlement{}, err
			}
		}
		return *final, tx.Commit(ctx)
	}
	if !day.Equal(enrollment.NextDay) {
		return earningsfloor.Settlement{}, earningsfloor.ErrDayOrder
	}
	end := day.Add(24 * time.Hour)
	optedIn, _, err := autopilotConsentAt(ctx, tx, machine.ancestors, &end)
	if err != nil {
		return earningsfloor.Settlement{}, err
	}
	receipt := earningsfloor.Settlement{
		MachineID: enrollment.MachineID, AccountID: machine.account, Day: day,
		FloorMicroUSD: enrollment.DailyFloorMicroUSD, CreatedAt: now,
	}
	switch {
	case enrollment.HistoryConflict:
		receipt.Status = earningsfloor.HistoryRequired
	case !optedIn:
		receipt.Status = earningsfloor.OptedOut
	case !enrollment.BaselineKnown:
		receipt.Status = earningsfloor.HistoryRequired
	default:
		receipt.InferenceMicroUSD, err = sumAutopilotInference(ctx, tx, machine, day, end)
		if err != nil {
			return earningsfloor.Settlement{}, err
		}
		receipt.DueMicroUSD = max(receipt.FloorMicroUSD-receipt.InferenceMicroUSD, 0)
		switch {
		case receipt.DueMicroUSD == 0:
			receipt.Status = earningsfloor.Zero
		case receipt.DueMicroUSD > pool.CapMicroUSD-pool.SpentMicroUSD:
			receipt.Status = earningsfloor.PoolExhausted
		default:
			receipt.Status = earningsfloor.Paid
			receipt.AmountMicroUSD = receipt.DueMicroUSD
		}
	}
	if receipt.AmountMicroUSD > 0 {
		if err := creditAutopilotReward(ctx, tx, machine.id, receipt, now); err != nil {
			return earningsfloor.Settlement{}, err
		}
		tag, err := tx.Exec(ctx, `UPDATE autopilot_reward_pool SET spent_micro_usd=spent_micro_usd+$1
		 WHERE singleton AND $1<=cap_micro_usd-spent_micro_usd`, receipt.AmountMicroUSD)
		if err != nil {
			return earningsfloor.Settlement{}, err
		}
		if tag.RowsAffected() != 1 {
			return earningsfloor.Settlement{}, earningsfloor.ErrPoolCap
		}
	}
	receipt, err = scanAutopilotRewardSettlement(tx.QueryRow(ctx, `INSERT INTO autopilot_reward_settlements
	 (machine_id,day,account_id,floor_micro_usd,inference_micro_usd,due_micro_usd,amount_micro_usd,status,created_at)
	 VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9) ON CONFLICT(machine_id,day) DO UPDATE SET
	 floor_micro_usd=EXCLUDED.floor_micro_usd,inference_micro_usd=EXCLUDED.inference_micro_usd,
	 due_micro_usd=EXCLUDED.due_micro_usd,amount_micro_usd=EXCLUDED.amount_micro_usd,status=EXCLUDED.status
	 WHERE autopilot_reward_settlements.status IN ('pool_exhausted','history_required')
	 RETURNING machine_id,account_id,day,floor_micro_usd,inference_micro_usd,due_micro_usd,amount_micro_usd,status,created_at`,
		receipt.MachineID, receipt.Day, receipt.AccountID, receipt.FloorMicroUSD, receipt.InferenceMicroUSD,
		receipt.DueMicroUSD, receipt.AmountMicroUSD, receipt.Status, receipt.CreatedAt))
	if err != nil {
		return earningsfloor.Settlement{}, err
	}
	if receipt.Status != earningsfloor.PoolExhausted && receipt.Status != earningsfloor.HistoryRequired {
		if err := advanceAutopilotRewardDay(ctx, tx, enrollment.MachineID, day); err != nil {
			return earningsfloor.Settlement{}, err
		}
	}
	return receipt, tx.Commit(ctx)
}

func finalizedAutopilotRewardDay(ctx context.Context, tx pgx.Tx, machine autopilotRewardMachine, day time.Time) (*earningsfloor.Settlement, error) {
	rows, err := tx.Query(ctx, `SELECT machine_id,account_id,day,floor_micro_usd,inference_micro_usd,due_micro_usd,amount_micro_usd,status,created_at
	 FROM autopilot_reward_settlements WHERE machine_id=ANY($1::text[]) AND day=$2
	 AND status IN ('paid','zero','opted_out') LIMIT 2`, machine.ancestors, day)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var final *earningsfloor.Settlement
	for rows.Next() {
		receipt, err := scanAutopilotRewardSettlement(rows)
		if err != nil {
			return nil, err
		}
		if final != nil || receipt.AccountID != machine.account {
			return nil, earningsfloor.ErrIdentity
		}
		final = &receipt
	}
	return final, rows.Err()
}

func scanAutopilotRewardSettlement(row rowScanner) (earningsfloor.Settlement, error) {
	var receipt earningsfloor.Settlement
	err := row.Scan(&receipt.MachineID, &receipt.AccountID, &receipt.Day, &receipt.FloorMicroUSD, &receipt.InferenceMicroUSD,
		&receipt.DueMicroUSD, &receipt.AmountMicroUSD, &receipt.Status, &receipt.CreatedAt)
	return receipt, err
}

func advanceAutopilotRewardDay(ctx context.Context, tx pgx.Tx, machineID string, day time.Time) error {
	tag, err := tx.Exec(ctx, `UPDATE autopilot_reward_enrollments SET next_day=$2 WHERE machine_id=$1 AND next_day=$3`, machineID, day.Add(24*time.Hour), day)
	if err != nil {
		return err
	}
	if tag.RowsAffected() != 1 {
		return earningsfloor.ErrDayOrder
	}
	return nil
}

func creditAutopilotReward(ctx context.Context, tx pgx.Tx, canonical string, receipt earningsfloor.Settlement, now time.Time) error {
	jobID := "autopilot-floor:" + receipt.MachineID + ":" + receipt.Day.Format(time.DateOnly)
	var earnings, balances, ledger, summaries int
	// SQL bigint arithmetic rejects balance/summary overflow. A conflicting job
	// is corruption, not a second idempotency path: the financial receipt above
	// must exist for a replay. Any error or suppressed row rolls back pool spend.
	err := tx.QueryRow(ctx, `WITH earning AS (
	 INSERT INTO provider_earnings(account_id,provider_id,provider_key,job_id,model,amount_micro_usd,prompt_tokens,completion_tokens,created_at)
	 VALUES($1,'',$2,$3,'base_reward',$4,0,0,$5) RETURNING account_id,amount_micro_usd
	), credit AS (
	 INSERT INTO balances(account_id,balance_micro_usd,withdrawable_micro_usd,updated_at)
	 SELECT account_id,amount_micro_usd,amount_micro_usd,$5 FROM earning
	 ON CONFLICT(account_id) DO UPDATE SET balance_micro_usd=balances.balance_micro_usd+EXCLUDED.balance_micro_usd,
	 withdrawable_micro_usd=balances.withdrawable_micro_usd+EXCLUDED.withdrawable_micro_usd,updated_at=EXCLUDED.updated_at
	 RETURNING account_id,balance_micro_usd
	), ledger AS (
	 INSERT INTO ledger_entries(account_id,entry_type,amount_micro_usd,balance_after,reference,created_at)
	 SELECT account_id,$6,$4,balance_micro_usd,$3,$5 FROM credit RETURNING id
	), summary AS (
	 INSERT INTO earnings_summary(key,key_type,total_count,total_micro_usd,total_prompt_tokens,total_completion_tokens,updated_at)
	 SELECT account_id,'account',0,amount_micro_usd,0,0,$5 FROM earning
	 ON CONFLICT(key,key_type) DO UPDATE SET total_micro_usd=earnings_summary.total_micro_usd+EXCLUDED.total_micro_usd,updated_at=EXCLUDED.updated_at
	 RETURNING key
	) SELECT (SELECT count(*) FROM earning),(SELECT count(*) FROM credit),(SELECT count(*) FROM ledger),(SELECT count(*) FROM summary)`,
		receipt.AccountID, store.MachineFloorKey(canonical), jobID, receipt.AmountMicroUSD, now, string(store.LedgerAutopilotFloor)).
		Scan(&earnings, &balances, &ledger, &summaries)
	if err != nil {
		return err
	}
	if earnings != 1 || balances != 1 || ledger != 1 || summaries != 1 {
		return errors.New("autopilot reward credit was suppressed")
	}
	return nil
}
