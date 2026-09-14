package postgres

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"github.com/jackc/pgx/v5"
)

// Keep two bounded queries rather than an OR over identity columns: each uses
// an ordered partial index and stops at the newest matching prior session.
func (s *Store) GetProviderForRestore(ctx context.Context, serial, seKey string, excludeIDs []string) (*contracts.ProviderRecord, error) {
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
