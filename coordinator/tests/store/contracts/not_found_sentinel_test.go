package store_test

import (
	"errors"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
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
				if !errors.Is(err, store.ErrNotFound) {
					t.Errorf("%s: errors.Is(err, ErrNotFound) = false; err = %v", method, err)
				}
				if got := err.Error(); got != want {
					t.Errorf("%s: message changed:\n got %q\nwant %q", method, got, want)
				}
			}
		})
	}
}
