package memory

import (
	"context"
	"errors"
	"math"
	"slices"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/internal/shared"
)

func (s *MemoryStore) GetMachineRewardBindings(ctx context.Context, sessions []string) (map[string]store.MachineRewardBinding, error) {
	sessions, err := shared.MachineRewardBatch(sessions)
	if err != nil {
		return nil, err
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make(map[string]store.MachineRewardBinding, len(sessions))
	m := s.machineInventory
	if m == nil {
		return out, nil
	}
	for _, session := range sessions {
		id := m.sessionMachines[session]
		observation, known := m.sessions[session]
		if !known || id == "" || observation.AccountID == "" || m.machines[id].Assurance == "provisional" {
			continue
		}
		aliases := []string{id}
		for source := range m.merged {
			next := source
			for i := 0; i < 100 && next != ""; i++ {
				if next == id {
					aliases = append(aliases, source)
					break
				}
				next = m.merged[next]
			}
		}
		slices.Sort(aliases)
		out[session] = store.MachineRewardBinding{MachineID: id, AccountID: observation.AccountID, MachineAliases: aliases}
	}
	return out, nil
}

func (s *MemoryStore) SumProviderEarningsByKeysForAccount(ctx context.Context, account string, keys []string, start, end time.Time) (int64, error) {
	keys, err := shared.MachineRewardBatch(keys)
	if err != nil {
		return 0, err
	}
	if err := ctx.Err(); err != nil {
		return 0, err
	}
	if account == "" {
		return 0, errors.New("machine_reward_account_required")
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	var total int64
	for _, e := range s.providerEarnings {
		if e.AccountID != account || !slices.Contains(keys, e.ProviderKey) || !isOrganicEarning(&e) || e.CreatedAt.Before(start) || !e.CreatedAt.Before(end) {
			continue
		}
		if e.AmountMicroUSD > math.MaxInt64-total {
			return 0, errors.New("machine_reward_earning_overflow")
		}
		total += e.AmountMicroUSD
	}
	return total, nil
}

var _ store.MachineRewardStore = (*MemoryStore)(nil)
