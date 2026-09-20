package store

import (
	"context"
	"errors"
	"math"
	"slices"
	"time"
)

// MachineRewardStore associates immutable session/earning keys with verified
// inventory. It never rewrites them or certifies physical-device uniqueness.
// Callers must independently verify live authorization and authenticated account.
type MachineRewardStore interface {
	GetMachineRewardBindings(context.Context, []string) (map[string]MachineRewardBinding, error)
	SumProviderEarningsByKeysForAccount(context.Context, string, []string, time.Time, time.Time) (int64, error)
	SettleMachineFloorDraw(context.Context, string, *ProviderFloorDraw) (bool, error)
	SettleProviderFloorDrawForSession(context.Context, string, *ProviderFloorDraw) (bool, error)
}

type MachineRewardBinding struct {
	MachineID string
	AccountID string
	// Prior machine IDs remain relevant when a floor was settled before a
	// verified alias merged identities. The canonical ID is included too.
	MachineAliases []string
}

const MachineRewardBatchLimit = 1000

// MachineFloorKey is only the key for newly issued floor credits. It never
// replaces request encryption keys, organic earning keys or older ledger rows.
func MachineFloorKey(machineID string) string { return "machine:" + machineID }

func machineRewardBatch(values []string) ([]string, error) {
	unique := make([]string, 0)
	seen := make(map[string]bool)
	for _, v := range values {
		if v == "" || seen[v] {
			continue
		}
		if len(unique) >= MachineRewardBatchLimit {
			return nil, errors.New("machine_reward_batch_too_large")
		}
		seen[v] = true
		unique = append(unique, v)
	}
	return unique, nil
}

func (s *MemoryStore) GetMachineRewardBindings(ctx context.Context, sessions []string) (map[string]MachineRewardBinding, error) {
	sessions, err := machineRewardBatch(sessions)
	if err != nil {
		return nil, err
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make(map[string]MachineRewardBinding, len(sessions))
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
		out[session] = MachineRewardBinding{MachineID: id, AccountID: observation.AccountID, MachineAliases: aliases}
	}
	return out, nil
}

func (s *MemoryStore) SumProviderEarningsByKeysForAccount(ctx context.Context, account string, keys []string, start, end time.Time) (int64, error) {
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

var (
	_ MachineRewardStore = (*MemoryStore)(nil)
	_ MachineRewardStore = (*PostgresStore)(nil)
)
