package observation_test

import (
	"net/http"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	production "github.com/eigeninference/d-inference/coordinator/api/observation"

	profile "github.com/eigeninference/d-inference/coordinator/internal/observation/profile"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

type profilerTestOwner struct {
	*production.Owner
	store    store.Store
	profiler *profile.Profiler
}

func newProfilerTestOwner(t *testing.T) *profilerTestOwner {
	t.Helper()
	st := memory.NewMemory(store.Config{})
	logger := quietLogger()
	a := access.New(st, logger, 1<<20, access.Hooks{})
	a.SetAdminKey("admin-test-key")
	p := profile.NewFromEnv(profile.Dependencies{Store: st, Logger: logger})
	o := production.New(production.Dependencies{Store: st, Registry: registry.New(logger), Logger: logger, Profiles: p, Hooks: production.Hooks{RequireAdminKey: a.RequireAdminKey}})
	t.Cleanup(o.Close)
	return &profilerTestOwner{Owner: o, store: st, profiler: p}
}

func profileAdminHandler(o *profilerTestOwner) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/admin/profiles", o.HandleAdminProfiles)
	mux.HandleFunc("GET /v1/admin/profiles/export", o.HandleAdminProfilesExport)
	mux.HandleFunc("GET /v1/admin/snapshots", o.HandleAdminSnapshots)
	return mux
}
