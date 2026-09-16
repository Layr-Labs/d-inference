package postgres

import (
	"context"
	"errors"
	"github.com/jackc/pgx/v5"
)

func (s *Store) CanonicalMachineID(ctx context.Context, id string) (string, error) {
	var canonical string
	err := s.pool.QueryRow(ctx, `WITH RECURSIVE chain AS (
	 SELECT id,merged_into,0 AS depth FROM darkbloom_machines WHERE id=$1
	 UNION ALL SELECT m.id,m.merged_into,c.depth+1 FROM darkbloom_machines m JOIN chain c ON c.merged_into=m.id WHERE c.depth<100)
	 SELECT id FROM chain WHERE merged_into IS NULL LIMIT 1`, id).Scan(&canonical)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil
	}
	return canonical, err
}
