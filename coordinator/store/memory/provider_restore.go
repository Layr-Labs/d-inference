package memory

import (
	"context"
	"slices"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

func (s *Store) GetProviderForRestore(ctx context.Context, serial, seKey string, excludeIDs []string) (*contracts.ProviderRecord, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	var serialMatch, keyMatch *contracts.ProviderRecord
	for _, p := range s.providerRecords {
		if slices.Contains(excludeIDs, p.ID) {
			continue
		}
		if serial != "" && p.SerialNumber == serial && newerProviderRecord(p, serialMatch) {
			serialMatch = p
		}
		if seKey != "" && p.SEPublicKey == seKey && newerProviderRecord(p, keyMatch) {
			keyMatch = p
		}
	}
	best := serialMatch
	if best == nil {
		best = keyMatch
	}
	if best == nil {
		return nil, nil
	}
	cp := *best
	if best.Location != nil {
		loc := *best.Location
		cp.Location = &loc
	}
	return &cp, nil
}

func newerProviderRecord(p, prior *contracts.ProviderRecord) bool {
	return prior == nil || p.LastSeen.After(prior.LastSeen) || (p.LastSeen.Equal(prior.LastSeen) && p.ID > prior.ID)
}
