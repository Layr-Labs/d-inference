package store

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
)

type MachineIdentityLookupStore interface {
	CanonicalMachineID(context.Context, string) (string, error)
}

const canonicalMachineIDQuery = `WITH RECURSIVE chain AS (
 SELECT id,merged_into,0 AS depth FROM darkbloom_machines WHERE id=$1
 UNION ALL SELECT m.id,m.merged_into,c.depth+1 FROM darkbloom_machines m JOIN chain c ON c.merged_into=m.id WHERE c.depth<100)
 SELECT id FROM chain WHERE merged_into IS NULL LIMIT 1`

func (s *PostgresStore) CanonicalMachineID(ctx context.Context, id string) (string, error) {
	var canonical string
	err := s.pool.QueryRow(ctx, canonicalMachineIDQuery, id).Scan(&canonical)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil
	}
	return canonical, err
}

func (s *MemoryStore) CanonicalMachineID(ctx context.Context, id string) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.canonicalMachineIDLocked(id)
}

// Caller holds s.mu, including across any admission using the result.
func (s *MemoryStore) canonicalMachineIDLocked(id string) (string, error) {
	if s.machineInventory == nil {
		return "", nil
	}
	for i := 0; i < 100; i++ {
		next := s.machineInventory.merged[id]
		if next == "" {
			if _, ok := s.machineInventory.machines[id]; ok {
				return id, nil
			}
			return "", nil
		}
		id = next
	}
	return "", errors.New("machine_merge_cycle")
}
