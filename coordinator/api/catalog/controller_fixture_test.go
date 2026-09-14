package catalog

import (
	"log/slog"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/readcache"
)

// Catalog-only fixtures exercise the same controllers without starting unrelated
// API services. Live publication, middleware, and provider tests stay in api.
type testController struct {
	*Controller
	adminCredential string
}

func newTestController(models ModelViews, st Store, logger *slog.Logger) *testController {
	h := &testController{}
	h.Controller = New(Dependencies{
		Store: func() Store { return st }, Models: models,
		Cache: readcache.New(), Logger: logger,
		AdminKey:         func() string { return h.adminCredential },
		SelfRouteAccount: func(*http.Request) (string, bool) { return "", false },
		SyncCatalog:      func() { h.Invalidate() },
	})
	return h
}

func (h *testController) SetAdminKey(key string) { h.adminCredential = key }
