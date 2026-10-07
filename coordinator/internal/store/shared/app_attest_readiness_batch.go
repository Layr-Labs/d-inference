package shared

import (
	"errors"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func ReadinessBatchKeys(keys []string) ([]string, error) {
	seen := make(map[string]struct{})
	unique := make([]string, 0)
	for _, key := range keys {
		if key == "" {
			continue
		}
		if _, ok := seen[key]; ok {
			continue
		}
		if len(unique) == store.AppAttestReadinessBatchLimit {
			return nil, errors.New("app_attest_readiness_batch_too_large")
		}
		seen[key] = struct{}{}
		unique = append(unique, key)
	}
	return unique, nil
}
