package store

import (
	"errors"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

// The user and model-registry getters must tag a true miss with ErrNotFound
// (so errors.Is works for the read-through cache and any other caller that
// distinguishes a miss from a transient failure) WITHOUT changing the rendered
// message: api.isModelRegistryNotFound and friends still string-match on
// "not found". Runs against the memory store always and Postgres when
// DATABASE_URL is set.
func TestNotFoundGettersWrapSentinelAndKeepMessage(t *testing.T) {
	for name, st := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			cases := []struct {
				name string
				call func() error
				want string
			}{
				{"GetUserByAccountID", func() error {
					_, err := st.GetUserByAccountID("acct-does-not-exist")
					return err
				}, "not found"},
				{"GetUserByPrivyID", func() error {
					_, err := st.GetUserByPrivyID("did:privy:does-not-exist")
					return err
				}, "not found"},
				{"GetModelRegistryRecord", func() error {
					_, err := st.GetModelRegistryRecord("mlx-community/does-not-exist")
					return err
				}, `model "mlx-community/does-not-exist" not found`},
				{"GetModelManifest", func() error {
					_, err := st.GetModelManifest("mlx-community/does-not-exist")
					return err
				}, `model "mlx-community/does-not-exist" not found`},
			}
			for _, tc := range cases {
				err := tc.call()
				if err == nil {
					t.Fatalf("%s: expected an error for a missing row", tc.name)
				}
				if !errors.Is(err, ErrNotFound) {
					t.Errorf("%s: errors.Is(err, ErrNotFound) = false; err = %v", tc.name, err)
				}
				if !strings.Contains(err.Error(), tc.want) {
					t.Errorf("%s: message %q lost expected substring %q", tc.name, err.Error(), tc.want)
				}
			}
		})
	}
}

// The Postgres user getters must NOT tag transient scan failures (anything
// other than pgx.ErrNoRows) with ErrNotFound -- a negative cache keyed on the
// sentinel would otherwise pin a DB blip as "no such user".
func TestWrapUserScanErrorOnlyTagsTrueMiss(t *testing.T) {
	transient := errors.New("connection reset")
	if err := wrapUserScanError(transient); errors.Is(err, ErrNotFound) {
		t.Fatalf("transient error must not carry ErrNotFound: %v", err)
	} else if !errors.Is(err, transient) {
		t.Fatalf("transient error must still be wrapped: %v", err)
	}

	miss := wrapUserScanError(pgx.ErrNoRows)
	if !errors.Is(miss, ErrNotFound) || !errors.Is(miss, pgx.ErrNoRows) {
		t.Fatalf("true miss must carry both sentinels: %v", miss)
	}
	if got, want := miss.Error(), "store: user not found: no rows in result set"; got != want {
		t.Fatalf("message changed: got %q want %q", got, want)
	}
}
