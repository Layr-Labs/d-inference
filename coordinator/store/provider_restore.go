package store

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"time"

	"github.com/jackc/pgx/v5"
)

// Keep two bounded queries rather than an OR over identity columns: each uses
// an ordered partial index and stops at the newest matching prior session.
func (s *PostgresStore) GetProviderForRestore(ctx context.Context, serial, seKey string, excludeIDs []string) (*ProviderRecord, error) {
	if excludeIDs == nil {
		excludeIDs = []string{}
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	for _, identity := range []struct{ column, value string }{
		{"serial_number", serial}, {"se_public_key", seKey},
	} {
		if identity.value == "" {
			continue
		}
		// column comes exclusively from the fixed literals above, never a caller.
		p, err := scanProviderRecord(s.pool.QueryRow(ctx, `SELECT `+providerRecordColumns+`
			FROM providers WHERE `+identity.column+` = $1 AND `+identity.column+` <> '' AND id <> ALL($2::text[])
			ORDER BY last_seen DESC, id DESC LIMIT 1`, identity.value, excludeIDs))
		if errors.Is(err, pgx.ErrNoRows) {
			continue
		}
		if err != nil {
			return nil, fmt.Errorf("store: lookup provider for restore: %w", err)
		}
		return p, nil
	}
	return nil, nil
}

func (s *MemoryStore) GetProviderForRestore(ctx context.Context, serial, seKey string, excludeIDs []string) (*ProviderRecord, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	var serialMatch, keyMatch *ProviderRecord
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

func newerProviderRecord(p, prior *ProviderRecord) bool {
	return prior == nil || p.LastSeen.After(prior.LastSeen) || (p.LastSeen.Equal(prior.LastSeen) && p.ID > prior.ID)
}
