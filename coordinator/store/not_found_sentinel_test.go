package store

import (
	"errors"
	"testing"

	"github.com/jackc/pgx/v5"
)

// The user and model-registry getters must tag a true miss with ErrNotFound
// (so errors.Is works for the read-through cache and any other caller that
// distinguishes a miss from a transient failure) WITHOUT changing the rendered
// message: api.isModelRegistryNotFound and friends still string-match on
// "not found". The expected strings are the exact pre-sentinel messages of
// each backend. Runs against the memory store always and Postgres when
// DATABASE_URL is set.
func TestNotFoundGettersWrapSentinelAndKeepMessage(t *testing.T) {
	const (
		missingAccount = "acct-does-not-exist"
		missingPrivy   = "did:privy:does-not-exist"
		missingModel   = "mlx-community/does-not-exist"
	)
	exact := map[string]map[string]string{
		"memory": {
			"GetUserByAccountID":     `user with account ID "` + missingAccount + `" not found`,
			"GetUserByPrivyID":       `user with Privy ID "` + missingPrivy + `" not found`,
			"GetModelRegistryRecord": `model "` + missingModel + `" not found`,
			"GetModelManifest":       `model "` + missingModel + `" not found`,
		},
		"postgres": {
			"GetUserByAccountID":     "store: user not found: no rows in result set",
			"GetUserByPrivyID":       "store: user not found: no rows in result set",
			"GetModelRegistryRecord": `model "` + missingModel + `" not found`,
			"GetModelManifest":       `model "` + missingModel + `" not found`,
		},
	}
	for name, st := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			calls := map[string]func() error{
				"GetUserByAccountID": func() error {
					_, err := st.GetUserByAccountID(missingAccount)
					return err
				},
				"GetUserByPrivyID": func() error {
					_, err := st.GetUserByPrivyID(missingPrivy)
					return err
				},
				"GetModelRegistryRecord": func() error {
					_, err := st.GetModelRegistryRecord(missingModel)
					return err
				},
				"GetModelManifest": func() error {
					_, err := st.GetModelManifest(missingModel)
					return err
				},
			}
			for method, call := range calls {
				want, known := exact[name][method]
				if !known {
					t.Fatalf("no exact message recorded for %s/%s", name, method)
				}
				err := call()
				if err == nil {
					t.Fatalf("%s: expected an error for a missing row", method)
				}
				if !errors.Is(err, ErrNotFound) {
					t.Errorf("%s: errors.Is(err, ErrNotFound) = false; err = %v", method, err)
				}
				if got := err.Error(); got != want {
					t.Errorf("%s: message changed:\n got %q\nwant %q", method, got, want)
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
	err := wrapUserScanError(transient)
	if errors.Is(err, ErrNotFound) {
		t.Fatalf("transient error must not carry ErrNotFound: %v", err)
	}
	if !errors.Is(err, transient) {
		t.Fatalf("transient error must still be wrapped: %v", err)
	}
	if got, want := err.Error(), "store: user not found: connection reset"; got != want {
		t.Fatalf("transient message changed: got %q want %q", got, want)
	}

	miss := wrapUserScanError(pgx.ErrNoRows)
	if !errors.Is(miss, ErrNotFound) || !errors.Is(miss, pgx.ErrNoRows) {
		t.Fatalf("true miss must carry both sentinels: %v", miss)
	}
	if got, want := miss.Error(), "store: user not found: no rows in result set"; got != want {
		t.Fatalf("miss message changed: got %q want %q", got, want)
	}
}
