package memory

import (
	"context"
	"errors"
	"math"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/payments/floorpolicy"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
)

type autopilotRewardDay struct {
	machineID string
	day       time.Time
}

func finalAutopilotRewardStatus(status string) bool {
	return status == earningsfloor.Paid || status == earningsfloor.Zero || status == earningsfloor.OptedOut
}

func (s *MemoryStore) SettleAutopilotRewardDay(ctx context.Context, machineID string, day time.Time) (earningsfloor.Settlement, error) {
	if err := ctx.Err(); err != nil {
		return earningsfloor.Settlement{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now().UTC().Truncate(time.Microsecond)
	if err := floorpolicy.ValidateDay(day, now); err != nil {
		return earningsfloor.Settlement{}, err
	}
	day = day.UTC()
	machine, err := s.autopilotRewardMachineLocked(machineID)
	if err != nil {
		return earningsfloor.Settlement{}, err
	}
	enrollment, err := s.autopilotRewardEnrollmentLocked(ctx, machine)
	if err != nil {
		return earningsfloor.Settlement{}, err
	}
	if enrollment.MachineID == "" {
		return earningsfloor.Settlement{}, store.ErrNotFound
	}
	var final earningsfloor.Settlement
	for ancestor := range machine.aliases {
		receipt, exists := s.autopilotRewardReceipts[autopilotRewardDay{ancestor, day}]
		if !exists || !finalAutopilotRewardStatus(receipt.Status) {
			continue
		}
		if final.MachineID != "" || receipt.AccountID != enrollment.AccountID {
			return earningsfloor.Settlement{}, earningsfloor.ErrIdentity
		}
		final = receipt
	}
	if final.MachineID != "" {
		if err := ctx.Err(); err != nil {
			return earningsfloor.Settlement{}, err
		}
		if day.Equal(enrollment.NextDay) {
			enrollment.NextDay = day.AddDate(0, 0, 1)
			s.autopilotRewardEnrollments[enrollment.MachineID] = enrollment
		}
		return final, nil
	}
	if !day.Equal(enrollment.NextDay) {
		return earningsfloor.Settlement{}, earningsfloor.ErrDayOrder
	}
	key := autopilotRewardDay{enrollment.MachineID, day}
	receipt := earningsfloor.Settlement{
		MachineID: enrollment.MachineID, AccountID: enrollment.AccountID, Day: day,
		FloorMicroUSD: enrollment.DailyFloorMicroUSD, CreatedAt: now,
	}
	if prior, exists := s.autopilotRewardReceipts[key]; exists {
		receipt.CreatedAt = prior.CreatedAt
	}
	optedIn, err := s.autopilotRewardOptedInBeforeLocked(machine, day.AddDate(0, 0, 1))
	if err != nil {
		return earningsfloor.Settlement{}, err
	}
	switch {
	case enrollment.HistoryConflict:
		receipt.Status = earningsfloor.HistoryRequired
	case !optedIn:
		receipt.Status = earningsfloor.OptedOut
	case !enrollment.BaselineKnown:
		receipt.Status = earningsfloor.HistoryRequired
	default:
		receipt.InferenceMicroUSD, err = s.autopilotRewardInferenceLocked(ctx, machine, day, day.AddDate(0, 0, 1))
		if errors.Is(err, earningsfloor.ErrHistory) {
			receipt.Status = earningsfloor.HistoryRequired
			break
		}
		if err != nil {
			return earningsfloor.Settlement{}, err
		}
		receipt.DueMicroUSD = max(int64(0), receipt.FloorMicroUSD-receipt.InferenceMicroUSD)
		switch {
		case receipt.DueMicroUSD == 0:
			receipt.Status = earningsfloor.Zero
		case receipt.DueMicroUSD > s.autopilotRewardPool.CapMicroUSD-s.autopilotRewardPool.SpentMicroUSD:
			receipt.Status = earningsfloor.PoolExhausted
		default:
			receipt.Status, receipt.AmountMicroUSD = earningsfloor.Paid, receipt.DueMicroUSD
		}
	}
	jobID := "autopilot-floor:" + enrollment.MachineID + ":" + day.Format(time.DateOnly)
	if receipt.AmountMicroUSD > 0 {
		if err := s.validateAutopilotRewardCreditLocked(enrollment.AccountID, jobID, receipt.AmountMicroUSD); err != nil {
			return earningsfloor.Settlement{}, err
		}
	}
	if err := ctx.Err(); err != nil {
		return earningsfloor.Settlement{}, err
	}
	if receipt.AmountMicroUSD > 0 {
		if !s.creditLocked(enrollment.AccountID, receipt.AmountMicroUSD, store.LedgerAutopilotFloor, jobID, now) {
			return earningsfloor.Settlement{}, store.ErrErasureConflict
		}
		s.withdrawable[enrollment.AccountID] += receipt.AmountMicroUSD
		s.providerEarningsSeq++
		s.history.ProviderEarnings = append(s.history.ProviderEarnings, store.ProviderEarning{
			ID: s.providerEarningsSeq, AccountID: enrollment.AccountID,
			ProviderKey: store.MachineFloorKey(machine.id), JobID: jobID,
			Model: "base_reward", AmountMicroUSD: receipt.AmountMicroUSD, CreatedAt: now,
		})
		s.autopilotRewardPool.SpentMicroUSD += receipt.AmountMicroUSD
	}
	if finalAutopilotRewardStatus(receipt.Status) {
		enrollment.NextDay = day.AddDate(0, 0, 1)
	}
	s.autopilotRewardReceipts[key] = receipt
	s.autopilotRewardEnrollments[enrollment.MachineID] = enrollment
	return receipt, nil
}

func (s *MemoryStore) validateAutopilotRewardCreditLocked(account, job string, amount int64) error {
	if s.balances[account] > math.MaxInt64-amount || s.withdrawable[account] > math.MaxInt64-amount || s.ledgerSeq == math.MaxInt64 || s.providerEarningsSeq == math.MaxInt64 {
		return errors.New("autopilot reward credit overflow")
	}
	var total int64
	for _, earning := range s.history.ProviderEarnings {
		if earning.JobID == job {
			return errors.New("autopilot reward earning already exists without a final receipt")
		}
		if earning.AccountID != account {
			continue
		}
		if earning.AmountMicroUSD > 0 && total > math.MaxInt64-earning.AmountMicroUSD || earning.AmountMicroUSD < 0 && total < math.MinInt64-earning.AmountMicroUSD {
			return errors.New("autopilot reward earnings summary overflow")
		}
		total += earning.AmountMicroUSD
	}
	if total > math.MaxInt64-amount {
		return errors.New("autopilot reward earnings summary overflow")
	}
	for _, entry := range s.history.LedgerEntries {
		if entry.Type == store.LedgerAutopilotFloor && entry.Reference == job {
			return errors.New("autopilot reward ledger already exists without a final receipt")
		}
	}
	return nil
}
