package observation

import (
	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"net/http"
	"testing"
)

func newProfilerTestOwner(t *testing.T) *Owner {
	t.Helper()
	st := memory.NewMemory(store.Config{})
	logger := quietLogger()
	a := access.New(st, logger, 1<<20, access.Hooks{})
	a.SetAdminKey("admin-test-key")
	o := New(Dependencies{Store: st, Registry: registry.New(logger), Logger: logger, Hooks: Hooks{RequireAdminKey: a.RequireAdminKey}})
	t.Cleanup(o.Close)
	return o
}

func profileAdminHandler(o *Owner) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/admin/profiles", o.HandleAdminProfiles)
	mux.HandleFunc("GET /v1/admin/profiles/export", o.HandleAdminProfilesExport)
	mux.HandleFunc("GET /v1/admin/snapshots", o.HandleAdminSnapshots)
	return mux
}
