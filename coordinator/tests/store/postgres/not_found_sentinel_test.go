package postgres_test

import (
	"errors"
	"testing"

	pgerrors "github.com/eigeninference/d-inference/coordinator/internal/store/pgerrors"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/jackc/pgx/v5"
)

// The Postgres user getters must NOT tag transient scan failures (anything
// other than pgx.ErrNoRows) with ErrNotFound -- a negative cache keyed on the
// sentinel would otherwise pin a DB blip as "no such user".
func TestWrapUserScanErrorOnlyTagsTrueMiss(t *testing.T) {
	transient := errors.New("connection reset")
	err := pgerrors.UserScan(transient)
	if errors.Is(err, store.ErrNotFound) {
		t.Fatalf("transient error must not carry ErrNotFound: %v", err)
	}
	if !errors.Is(err, transient) {
		t.Fatalf("transient error must still be wrapped: %v", err)
	}
	if got, want := err.Error(), "store: user not found: connection reset"; got != want {
		t.Fatalf("transient message changed: got %q want %q", got, want)
	}

	miss := pgerrors.UserScan(pgx.ErrNoRows)
	if !errors.Is(miss, store.ErrNotFound) || !errors.Is(miss, pgx.ErrNoRows) {
		t.Fatalf("true miss must carry both sentinels: %v", miss)
	}
	if got, want := miss.Error(), "store: user not found: no rows in result set"; got != want {
		t.Fatalf("miss message changed: got %q want %q", got, want)
	}
}
