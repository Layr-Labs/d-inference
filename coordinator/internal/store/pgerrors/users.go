package pgerrors

import (
	"errors"
	"fmt"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/jackc/pgx/v5"
)

// wrapUserScanError preserves the historical "store: user not found: ..."
// message for every scan failure, and additionally tags a true miss
// (pgx.ErrNoRows) with ErrNotFound so callers -- including the read-through
// cache -- can distinguish "no such user" from a transient DB error with
// errors.Is. ErrNotFound.Error() is exactly "not found", so the rendered
// string is byte-for-byte unchanged.
func UserScan(err error) error {
	if errors.Is(err, pgx.ErrNoRows) {
		return fmt.Errorf("store: user %w: %w", store.ErrNotFound, err)
	}
	return fmt.Errorf("store: user not found: %w", err)
}
