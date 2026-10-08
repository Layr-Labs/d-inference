package postgres

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/payments/floorpolicy"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
	"github.com/jackc/pgx/v5"
)

var _ store.AutopilotRewardsStore = (*PostgresStore)(nil)

func readAutopilotRewardEnrollment(ctx context.Context, tx pgx.Tx, ancestors []string) (*earningsfloor.Enrollment, error) {
	var enrollment earningsfloor.Enrollment
	err := tx.QueryRow(ctx, `SELECT machine_id,account_id,first_observed_at,first_opt_in_at,
	 seven_day_earnings_micro_usd,daily_floor_micro_usd,baseline_known,baseline_source,baseline_evidence,next_day,
	 e.baseline_known AND (
	  EXISTS(SELECT 1 FROM autopilot_reward_consents c WHERE c.machine_id=ANY($1::text[])
	   AND c.supported AND c.opted_in AND c.at<e.first_opt_in_at)
	  OR EXISTS(SELECT 1 FROM autopilot_reward_enrollments prior WHERE prior.machine_id=ANY($1::text[])
	   AND NOT prior.baseline_known AND prior.first_observed_at<e.first_opt_in_at)) AS history_conflict
	 FROM autopilot_reward_enrollments e WHERE machine_id=ANY($1::text[])
	 ORDER BY baseline_known DESC,first_opt_in_at NULLS LAST,first_observed_at,machine_id LIMIT 1`, ancestors).
		Scan(&enrollment.MachineID, &enrollment.AccountID, &enrollment.FirstObservedAt, &enrollment.FirstOptInAt,
			&enrollment.SevenDayEarningsMicroUSD, &enrollment.DailyFloorMicroUSD, &enrollment.BaselineKnown, &enrollment.BaselineSource, &enrollment.BaselineEvidence, &enrollment.NextDay, &enrollment.HistoryConflict)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	return &enrollment, err
}

func ensureAutopilotRewardEnrollment(ctx context.Context, tx pgx.Tx, machine autopilotRewardMachine, pool earningsfloor.Pool) (*earningsfloor.Enrollment, error) {
	enrollment, err := readAutopilotRewardEnrollment(ctx, tx, machine.ancestors)
	if err != nil {
		return enrollment, err
	}
	if enrollment != nil {
		if (enrollment.BaselineSource == earningsfloor.TrackedBaseline || enrollment.BaselineSource == earningsfloor.CohortBaseline) && !enrollment.HistoryConflict {
			complete, err := autopilotRewardTrackingComplete(ctx, tx, machine, pool, *enrollment.FirstOptInAt)
			if err != nil {
				return nil, err
			}
			enrollment.HistoryConflict = !complete
		}
		return enrollment, nil
	}
	var firstPositive *time.Time
	err = tx.QueryRow(ctx, `SELECT min(at) FROM autopilot_reward_consents
	 WHERE machine_id=ANY($1::text[]) AND opted_in AND supported`, machine.ancestors).Scan(&firstPositive)
	if err != nil || firstPositive == nil {
		return nil, err
	}
	complete, err := autopilotRewardTrackingComplete(ctx, tx, machine, pool, *firstPositive)
	if err != nil {
		return nil, err
	}
	enrollment = &earningsfloor.Enrollment{
		MachineID: machine.id, AccountID: machine.account,
		FirstObservedAt: firstPositive.UTC(), NextDay: floorpolicy.Day(*firstPositive),
		BaselineKnown: complete,
	}
	if enrollment.NextDay.Before(floorpolicy.Day(pool.TrackingStartedAt)) {
		enrollment.NextDay = floorpolicy.Day(pool.TrackingStartedAt)
	}
	if enrollment.BaselineKnown {
		enrollment.SevenDayEarningsMicroUSD, enrollment.BaselineSource, enrollment.BaselineEvidence, err = autopilotRewardBaseline(ctx, tx, machine, *firstPositive)
		if errors.Is(err, earningsfloor.ErrHistory) {
			enrollment.BaselineKnown = false
		} else if err != nil {
			return nil, err
		}
	}
	if enrollment.BaselineKnown {
		enrollment.DailyFloorMicroUSD, err = floorpolicy.DailyFloor(enrollment.SevenDayEarningsMicroUSD)
		if err != nil {
			return nil, err
		}
		enrollment.FirstOptInAt = firstPositive
	}
	_, err = tx.Exec(ctx, `INSERT INTO autopilot_reward_enrollments(machine_id,account_id,first_observed_at,first_opt_in_at,
	 seven_day_earnings_micro_usd,daily_floor_micro_usd,baseline_known,baseline_source,baseline_evidence,next_day)
	 VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)`, enrollment.MachineID, enrollment.AccountID, enrollment.FirstObservedAt, enrollment.FirstOptInAt,
		enrollment.SevenDayEarningsMicroUSD, enrollment.DailyFloorMicroUSD, enrollment.BaselineKnown, enrollment.BaselineSource, enrollment.BaselineEvidence, enrollment.NextDay)
	return enrollment, err
}

// A tracked first-ever anchor depends on complete consent tracking, not just on
// its original lookup. Recheck that proof after late bindings and merges without
// revisiting frozen payout totals. Verified history does not use this inference.
func autopilotRewardTrackingComplete(ctx context.Context, tx pgx.Tx, machine autopilotRewardMachine, pool earningsfloor.Pool, anchor time.Time) (bool, error) {
	if machine.firstSeen.Before(pool.TrackingStartedAt) || anchor.Before(pool.TrackingStartedAt) {
		return false, nil
	}
	var complete bool
	err := tx.QueryRow(ctx, `SELECT
	 EXISTS(SELECT 1 FROM autopilot_reward_consents c WHERE c.machine_id=ANY($1::text[]) AND c.supported AND c.at<=$3)
	 AND NOT EXISTS(SELECT 1 FROM autopilot_reward_consents c WHERE c.machine_id=ANY($1::text[]) AND NOT c.supported AND c.at<=$4)
	 AND NOT EXISTS(SELECT 1 FROM autopilot_reward_consents c WHERE c.account_id=$2 AND c.machine_id IS NULL
	  AND c.opted_in AND c.supported AND c.at<=$4
	  AND NOT EXISTS(SELECT 1 FROM darkbloom_machine_sessions s JOIN darkbloom_machines m ON m.id=s.machine_id
	   WHERE s.session_id=c.session_id AND s.account_id=c.account_id AND m.assurance<>'provisional'))`,
		machine.ancestors, machine.account, machine.firstSeen, anchor).Scan(&complete)
	return complete, err
}

func projectAutopilotRewardEnrollment(ctx context.Context, tx pgx.Tx, machine autopilotRewardMachine, enrollment *earningsfloor.Enrollment) (earningsfloor.Enrollment, error) {
	if enrollment == nil {
		return earningsfloor.Enrollment{}, nil
	}
	projected := *enrollment
	projected.MachineID = machine.id
	var err error
	projected.OptedIn, _, projected.ObservedAt, err = autopilotConsentAt(ctx, tx, machine.ancestors, nil)
	return projected, err
}

func (s *PostgresStore) autopilotRewardEnrollment(ctx context.Context, machineID string) (earningsfloor.Enrollment, error) {
	tx, machine, pool, err := s.beginAutopilotRewardMachineWrite(ctx, machineID)
	if err != nil {
		return earningsfloor.Enrollment{}, err
	}
	defer rollbackErasureTx(tx)
	enrollment, err := ensureAutopilotRewardEnrollment(ctx, tx, machine, pool)
	if err != nil {
		return earningsfloor.Enrollment{}, err
	}
	projected, err := projectAutopilotRewardEnrollment(ctx, tx, machine, enrollment)
	if err != nil {
		return earningsfloor.Enrollment{}, err
	}
	return projected, tx.Commit(ctx)
}

func (s *PostgresStore) RestoreAutopilotBaseline(ctx context.Context, baseline earningsfloor.Baseline) (earningsfloor.Enrollment, error) {
	baseline.FirstOptInAt = baseline.FirstOptInAt.UTC().Truncate(time.Microsecond)
	if baseline.MachineID == "" || baseline.FirstOptInAt.IsZero() || strings.TrimSpace(baseline.Evidence) == "" || len(baseline.Evidence) > 1024 {
		return earningsfloor.Enrollment{}, earningsfloor.ErrHistory
	}
	floor, err := floorpolicy.DailyFloor(baseline.SevenDayEarningsMicroUSD)
	if err != nil {
		return earningsfloor.Enrollment{}, err
	}
	tx, machine, pool, err := s.beginAutopilotRewardMachineWrite(ctx, baseline.MachineID)
	if err != nil {
		return earningsfloor.Enrollment{}, err
	}
	defer rollbackErasureTx(tx)
	enrollment, err := ensureAutopilotRewardEnrollment(ctx, tx, machine, pool)
	if err != nil {
		return earningsfloor.Enrollment{}, err
	}
	if enrollment == nil {
		return earningsfloor.Enrollment{}, store.ErrNotFound
	}
	if enrollment.BaselineKnown {
		return earningsfloor.Enrollment{}, earningsfloor.ErrBaselineFrozen
	}
	if baseline.FirstOptInAt.After(enrollment.FirstObservedAt) {
		return earningsfloor.Enrollment{}, earningsfloor.ErrHistory
	}
	enrollment.FirstOptInAt = &baseline.FirstOptInAt
	enrollment.SevenDayEarningsMicroUSD = baseline.SevenDayEarningsMicroUSD
	enrollment.DailyFloorMicroUSD = floor
	enrollment.BaselineKnown = true
	enrollment.BaselineSource = earningsfloor.VerifiedBaseline
	enrollment.BaselineEvidence = baseline.Evidence
	_, err = tx.Exec(ctx, `UPDATE autopilot_reward_enrollments SET first_opt_in_at=$2,seven_day_earnings_micro_usd=$3,
	 daily_floor_micro_usd=$4,baseline_known=true,baseline_source=$5,baseline_evidence=$6 WHERE machine_id=$1`, enrollment.MachineID,
		enrollment.FirstOptInAt, enrollment.SevenDayEarningsMicroUSD, enrollment.DailyFloorMicroUSD, enrollment.BaselineSource, enrollment.BaselineEvidence)
	if err != nil {
		return earningsfloor.Enrollment{}, err
	}
	enrollment, err = readAutopilotRewardEnrollment(ctx, tx, machine.ancestors)
	if err != nil {
		return earningsfloor.Enrollment{}, err
	}
	projected, err := projectAutopilotRewardEnrollment(ctx, tx, machine, enrollment)
	if err != nil {
		return earningsfloor.Enrollment{}, err
	}
	return projected, tx.Commit(ctx)
}
