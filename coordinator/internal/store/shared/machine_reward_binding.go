package shared

import (
	"errors"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func MachineRewardBatch(values []string) ([]string, error) {
	unique := make([]string, 0)
	seen := make(map[string]bool)
	for _, v := range values {
		if v == "" || seen[v] {
			continue
		}
		if len(unique) >= store.MachineRewardBatchLimit {
			return nil, errors.New("machine_reward_batch_too_large")
		}
		seen[v] = true
		unique = append(unique, v)
	}
	return unique, nil
}
