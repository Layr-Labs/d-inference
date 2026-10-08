package memory

import (
	"context"
	"errors"
	"slices"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/payments/floorpolicy"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
)

var _ store.AutopilotRewardsStore = (*MemoryStore)(nil)
var _ store.AutopilotConsentJournal = (*MemoryStore)(nil)

func (s *MemoryStore) AutopilotRewardPool(ctx context.Context) (earningsfloor.Pool, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if err := ctx.Err(); err != nil {
		return earningsfloor.Pool{}, err
	}
	return s.autopilotRewardPool, nil
}

func (s *MemoryStore) SetAutopilotRewardPoolCap(ctx context.Context, capMicroUSD int64) (earningsfloor.Pool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if capMicroUSD < 0 || capMicroUSD < s.autopilotRewardPool.SpentMicroUSD {
		return earningsfloor.Pool{}, earningsfloor.ErrPoolCap
	}
	if err := ctx.Err(); err != nil {
		return earningsfloor.Pool{}, err
	}
	s.autopilotRewardPool.CapMicroUSD = capMicroUSD
	return s.autopilotRewardPool, nil
}

func (s *MemoryStore) RestoreAutopilotBaseline(ctx context.Context, baseline earningsfloor.Baseline) (earningsfloor.Enrollment, error) {
	if err := ctx.Err(); err != nil {
		return earningsfloor.Enrollment{}, err
	}
	baseline.FirstOptInAt = baseline.FirstOptInAt.UTC().Truncate(time.Microsecond)
	if baseline.MachineID == "" || baseline.FirstOptInAt.IsZero() || strings.TrimSpace(baseline.Evidence) == "" || len(baseline.Evidence) > 1024 {
		return earningsfloor.Enrollment{}, earningsfloor.ErrHistory
	}
	floor, err := floorpolicy.DailyFloor(baseline.SevenDayEarningsMicroUSD)
	if err != nil {
		return earningsfloor.Enrollment{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	machine, err := s.autopilotRewardMachineLocked(baseline.MachineID)
	if err != nil {
		return earningsfloor.Enrollment{}, err
	}
	enrollment, err := s.autopilotRewardEnrollmentLocked(ctx, machine)
	if err != nil {
		return earningsfloor.Enrollment{}, err
	}
	if enrollment.MachineID == "" {
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
	declarations, err := s.autopilotRewardDeclarationsLocked(machine)
	if err != nil {
		return earningsfloor.Enrollment{}, err
	}
	enrollment.HistoryConflict = s.autopilotRewardHistoryConflictLocked(machine, declarations, enrollment)
	if err := ctx.Err(); err != nil {
		return earningsfloor.Enrollment{}, err
	}
	s.autopilotRewardEnrollments[enrollment.MachineID] = enrollment
	return projectAutopilotRewardEnrollment(enrollment, machine.id), nil
}

func (s *MemoryStore) AutopilotRewardEnrollments(ctx context.Context, after string, limit int) ([]earningsfloor.Enrollment, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if limit <= 0 {
		limit = 100
	} else if limit > 200 {
		limit = 200
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]earningsfloor.Enrollment, 0)
	if s.machineInventory == nil {
		return out, nil
	}
	ids := make([]string, 0, len(s.machineInventory.Machines))
	for id := range s.machineInventory.Machines {
		if id > after {
			ids = append(ids, id)
		}
	}
	slices.Sort(ids)
	var staged []earningsfloor.Enrollment
	for _, id := range ids {
		machine, err := s.autopilotRewardMachineLocked(id)
		if errors.Is(err, earningsfloor.ErrIdentity) || errors.Is(err, store.ErrErasureConflict) {
			continue
		}
		if err != nil {
			return nil, err
		}
		enrollment, err := s.autopilotRewardEnrollmentLocked(ctx, machine)
		if errors.Is(err, earningsfloor.ErrIdentity) {
			continue
		}
		if err != nil {
			return nil, err
		}
		if enrollment.MachineID == "" {
			continue
		}
		// A disconnected registration may have journaled before its inventory
		// write. Materialize it here without requiring a surviving connection.
		staged = append(staged, enrollment)
		out = append(out, projectAutopilotRewardEnrollment(enrollment, machine.id))
		if len(out) == limit {
			break
		}
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	for _, enrollment := range staged {
		s.autopilotRewardEnrollments[enrollment.MachineID] = enrollment
	}
	return out, nil
}
